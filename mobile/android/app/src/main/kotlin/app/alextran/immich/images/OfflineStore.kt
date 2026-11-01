package app.alextran.immich.images

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.util.Log
import app.alextran.immich.NativeBuffer
import app.alextran.immich.NativeByteBuffer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.concurrent.Executors
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * immich-sync fork: the offline store, Android side. The counterpart of `OfflineStore.swift`; names
 * and buckets come from the native core ([OfflineNaming]). The Dart reconciler writes what
 * selections ask for and the image path keeps whatever was looked at; nothing here deletes. This
 * side reports what it stored and served so Dart can record it.
 */
object OfflineStore {
  /** `filesDir`, not `cacheDir`, which the system may empty at will. */
  private var root: File? = null
  private var pinnedRoot: File? = null

  /** Reads happen here, off the thread that asked. Writes are serialised on their own. */
  private val io = Executors.newFixedThreadPool(4)
  private val writes = Executors.newSingleThreadExecutor()
  private val maintenance = Executors.newSingleThreadExecutor()

  private val lock = ReentrantLock()

  /**
   * 64-bit name hashes of every stored file, so a miss costs no filesystem access. A collision
   * costs one wasted open, never a wrong image.
   */
  private val present = HashSet<Long>()
  private var indexed = false

  /**
   * Files stored (with sizes) and served since Dart was last told, sent every couple of seconds.
   */
  private val storedSince = ArrayList<Pair<String, Long>>()
  private val readSince = HashSet<String>()
  private var reportScheduled = false
  private const val REPORT_DELAY_MS = 2000L
  private const val TAG = "OfflineStore"
  /** Lazy, so plain JVM tests can load this object without a looper. */
  private val main by lazy { Handler(Looper.getMainLooper()) }
  internal var channel: MethodChannel? = null

  // Naming.

  /** Name hash from the native core; 0 without it, when nothing can be named, stored or read anyway. */
  private fun nameHash(name: String): Long = try {
    OfflineNaming.nameHash(name)
  } catch (_: Throwable) {
    0L
  }

  /** Filename for a remote URL, from the native core; null for one never stored. */
  fun fileName(url: String): String? = try {
    OfflineNaming.fileName(url)
  } catch (_: Throwable) {
    null
  }

  /** Bucket a name falls into; null without the native core, like [fileName]. */
  fun bucket(name: String): String? = try {
    String.format("%02x", OfflineNaming.bucket(name))
  } catch (_: Throwable) {
    null
  }

  private fun pinnedPath(name: String): File? {
    val pinned = pinnedRoot ?: return null
    val bucket = bucket(name) ?: return null
    return File(File(pinned, bucket), name)
  }

  // Lifecycle.

  /**
   * Creates the store and indexes it, once at launch. Until the index is built every lookup checks
   * the filesystem.
   */
  fun prepare(context: Context) {
    val base = File(context.filesDir, "mirrich_blobs")
    OfflineDownloader.prepare(context, base)
    val pinned = File(base, "pinned")
    lock.withLock {
      root = base
      pinnedRoot = pinned
    }
    pinned.mkdirs()

    // Without the core no file can be named, so every read misses and nothing is stored: say so once.
    if (fileName("https://offline.invalid/api/assets/x/thumbnail") == null) {
      Log.e(TAG, "The native core's naming is unavailable; offline copies cannot be read or stored")
    }

    maintenance.execute {
      // Where older builds kept browsed files. Nothing recorded them, so they are dropped.
      val legacyCache = File(base, "cache")
      if (legacyCache.exists()) legacyCache.deleteRecursively()

      val hashes = HashSet<Long>()
      for (file in walk(pinned)) hashes.add(nameHash(file.name))
      lock.withLock {
        present.addAll(hashes)
        indexed = true
      }
    }
  }

  /** Every regular file under a directory. Hidden files included, as in the Dart integrity pass. */
  private fun walk(directory: File): List<File> =
    directory.walkTopDown().filter { it.isFile }.toList()

  /** Bytes free on the volume the store is on, or null before [prepare]. */
  fun freeSpace(): Long? {
    val directory = lock.withLock { root } ?: return null
    return try {
      StatFs(directory.path).availableBytes
    } catch (_: Throwable) {
      null
    }
  }

  // Reading.

  /** Whether a lookup is worth a filesystem call. Safe to call on any thread. */
  fun mightHold(name: String): Boolean = lock.withLock {
    if (indexed) present.contains(nameHash(name)) else true
  }

  /** Runs [body] on the store's own pool. */
  fun read(body: () -> Unit) {
    io.execute(body)
  }

  /**
   * Stored bytes for a name, or null. Read straight into an off-heap buffer through a mapped
   * channel. A hit counts as a use.
   */
  fun load(name: String): NativeByteBuffer? {
    val file = pinnedPath(name)?.takeIf { it.isFile } ?: return null
    val length = file.length()
    if (length <= 0 || length > Int.MAX_VALUE) return null

    val buffer = NativeByteBuffer(length.toInt())
    try {
      RandomAccessFile(file, "r").use { handle ->
        handle.channel.use { channel ->
          val target = NativeBuffer.wrap(buffer.pointer, length.toInt())
          var read = 0
          while (read < length) {
            val count = channel.read(target)
            if (count <= 0) break
            read += count
          }
          if (read.toLong() != length) {
            buffer.free()
            return null
          }
          buffer.advance(read)
        }
      }
    } catch (_: Throwable) {
      buffer.free()
      return null
    }
    lock.withLock { readSince.add(name) }
    scheduleReport()
    return buffer
  }

  private val JXL_CONTAINER = byteArrayOf(0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87.toByte(), 0x0A)

  /**
   * The content type the image path decides by, told from a stored file's signature since none is kept. Only the types
   * it treats specially: JPEG XL, and raw files in a TIFF container, whose orientation is read from it.
   */
  fun contentTypeOf(buffer: NativeByteBuffer): String? {
    val size = buffer.offset
    if (size < 4) return null
    val bytes = NativeBuffer.wrap(buffer.pointer, size)
    val b0 = bytes.get(0)
    val b1 = bytes.get(1)
    return when {
      b0 == 0xFF.toByte() && b1 == 0x0A.toByte() -> "image/jxl"
      size >= JXL_CONTAINER.size && JXL_CONTAINER.indices.all { bytes.get(it) == JXL_CONTAINER[it] } -> "image/jxl"
      (b0 == 0x49.toByte() && b1 == 0x49.toByte()) || (b0 == 0x4D.toByte() && b1 == 0x4D.toByte()) -> "image/raw"
      else -> null
    }
  }

  // Writing.

  /**
   * Whether a response's bytes may be kept: an image (or a video, for the queue), or a type the server did not name. A
   * login page or portal that answers with 200 is not, since a kept file is served ahead of the network from then on.
   */
  fun keepsType(contentType: String?, video: Boolean = false): Boolean {
    val type = contentType?.substringBefore(';')?.trim()?.lowercase() ?: return true
    return type.isEmpty() || type.startsWith("image/") || type == "application/octet-stream" ||
      (video && type.startsWith("video/"))
  }

  /**
   * Keeps bytes just fetched for the screen. They are spares until a selection wants the same file. Takes [buffer] and
   * frees it once written: off the heap, since an original can be tens of megabytes.
   */
  fun store(buffer: NativeByteBuffer, name: String) {
    val target = pinnedPath(name)
    if (target == null) {
      buffer.free()
      return
    }
    val size = buffer.offset

    try {
      writes.execute {
        try {
          write(buffer, size, target, name)
        } finally {
          buffer.free()
        }
      }
    } catch (error: Throwable) {
      buffer.free()
      throw error
    }
  }

  private fun write(buffer: NativeByteBuffer, size: Int, target: File, name: String) {
    // Already here: nothing to add or report. An empty file is what a crash can leave, so it is replaced.
    if (target.length() > 0) return
    target.parentFile?.mkdirs()

    // Written aside and renamed, so a half-written file is never read.
    val temporary = File(target.parentFile, "$name.part")
    try {
      FileOutputStream(temporary).use { stream ->
        val source = NativeBuffer.wrap(buffer.pointer, size)
        while (source.hasRemaining()) stream.channel.write(source)
        // On disk before the rename, or a power cut can leave the name with none of the bytes.
        stream.fd.sync()
      }
      if (!temporary.renameTo(target)) {
        temporary.delete()
        return
      }
    } catch (_: Throwable) {
      temporary.delete()
      return
    }

    lock.withLock {
      present.add(nameHash(name))
      storedSince.add(name to size.toLong())
    }
    scheduleReport()
  }

  /** Records names Dart has just written, so the next lookup finds them. */
  fun noteStored(names: List<String>) {
    lock.withLock { for (name in names) present.add(nameHash(name)) }
  }

  /** Forgets names Dart has just deleted; cheaper than [forgetAll]. */
  fun noteRemoved(names: List<String>) {
    lock.withLock { for (name in names) present.remove(nameHash(name)) }
  }

  /** Forgets everything and rebuilds from a walk, after a bulk delete. */
  fun forgetAll(context: Context) {
    lock.withLock {
      present.clear()
      indexed = false
    }
    prepare(context)
  }

  // Reporting.

  /**
   * Sends what happened to Dart a little later, so a screenful of tiles is one message. A report
   * nobody receives is harmless: the reconciler or the integrity pass catches up.
   */
  private fun scheduleReport() {
    val first = lock.withLock {
      val first = !reportScheduled
      reportScheduled = true
      first
    }
    if (!first) return

    main.postDelayed({
      val (stored, read) = lock.withLock {
        val stored = storedSince.map { listOf(it.first, it.second) }
        val read = readSince.toList()
        storedSince.clear()
        readSince.clear()
        reportScheduled = false
        stored to read
      }
      if (stored.isEmpty() && read.isEmpty()) return@postDelayed
      channel?.invokeMethod("activity", mapOf("stored" to stored, "read" to read))
    }, REPORT_DELAY_MS)
  }
}

/**
 * immich-sync fork: keeps the lookup index in step with Dart, and tells Dart what the image path
 * did.
 */
object OfflineStoreChannel {
  /**
   * The app's own engine. The background worker's engine registers the same channel, and if it
   * took the reports they would stop reaching the app until it restarted.
   */
  @Volatile private var appMessenger: BinaryMessenger? = null

  fun registerAppEngine(messenger: BinaryMessenger) {
    appMessenger = messenger
  }

  fun register(context: Context, messenger: BinaryMessenger) {
    val channel = MethodChannel(messenger, "mirrich/offline_store")
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        // Only the app's engine is told what the image path did.
        "listen" -> {
          val accepted = messenger === appMessenger
          if (accepted) OfflineStore.channel = channel
          result.success(accepted)
        }

        "noteStored" -> {
          @Suppress("UNCHECKED_CAST")
          OfflineStore.noteStored(call.arguments as? List<String> ?: emptyList())
          result.success(null)
        }

        "noteRemoved" -> {
          @Suppress("UNCHECKED_CAST")
          OfflineStore.noteRemoved(call.arguments as? List<String> ?: emptyList())
          result.success(null)
        }

        "forgetAll" -> {
          OfflineStore.forgetAll(context)
          result.success(null)
        }

        "freeSpace" -> result.success(OfflineStore.freeSpace())

        "download" -> {
          val id = call.argument<String>("id")
          val url = call.argument<String>("url")
          val path = call.argument<String>("path")
          if (id == null || url == null || path == null) {
            result.error("network", "Invalid arguments", null)
            return@setMethodCallHandler
          }
          val lane = if (call.argument<String>("lane") == "heavy") {
            OfflineDownloader.Lane.HEAVY
          } else {
            OfflineDownloader.Lane.LIGHT
          }
          OfflineDownloader.download(
            id,
            url,
            path,
            lane,
            call.argument<String>("checksum"),
            call.argument<Boolean>("wifiOnly") ?: false,
          ) {
            when (it) {
              is OfflineDownloader.DownloadResult.Done -> result.success(it.size)
              is OfflineDownloader.DownloadResult.Failed -> result.error(
                when {
                  it.corrupt -> "integrity"
                  it.statusCode != null -> "http"
                  else -> "network"
                },
                it.message,
                it.statusCode,
              )

              OfflineDownloader.DownloadResult.Cancelled -> result.error("cancelled", null, null)
            }
          }
        }

        "cancelDownload" -> {
          OfflineDownloader.cancel(call.arguments as? String ?: "")
          result.success(null)
        }

        "cancelAll" -> {
          OfflineDownloader.cancelAll()
          result.success(null)
        }

        "keepAlive" -> {
          val pending = call.argument<Int>("pending") ?: 0
          val wifiOnly = call.argument<Boolean>("wifiOnly") ?: false
          result.success(OfflineTransferKeepAlive.renew(pending, wifiOnly))
        }

        else -> result.notImplemented()
      }
    }
  }
}
