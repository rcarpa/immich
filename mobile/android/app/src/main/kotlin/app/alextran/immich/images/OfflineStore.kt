package app.alextran.immich.images

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import app.alextran.immich.NativeBuffer
import app.alextran.immich.NativeByteBuffer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.net.URI
import java.net.URLDecoder
import java.util.concurrent.Executors
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * immich-sync fork: the blob store, Android side. The counterpart of
 * `ios/Runner/Images/OfflineStore.swift`, and the same store — the names and the bucketing are
 * defined once in `lib/utils/offline_paths.dart` and reproduced here.
 *
 * One region, `pinned/`, written by two parties: the Dart reconciler for what the selections ask
 * for, and the image path below for whatever was looked at. Nothing here deletes anything —
 * deciding what may go needs the selection, which lives in Dart's database. This side reports the
 * files it stored and the files it served, and Dart evicts the least recently used spares when the
 * store needs room (FORK.md §3.4).
 */
object OfflineStore {
  /**
   * `filesDir`, not `cacheDir`: the library is not a cache and the system may empty the latter at
   * will. It is the same distinction Application Support and Caches draw on iOS.
   */
  private var root: File? = null
  private var pinnedRoot: File? = null

  /** Reads happen here, off the thread that asked. Writes are serialised on their own. */
  private val io = Executors.newFixedThreadPool(4)
  private val writes = Executors.newSingleThreadExecutor()
  private val maintenance = Executors.newSingleThreadExecutor()

  private val lock = ReentrantLock()

  /**
   * 64-bit name hashes of every file held. Answers "is it worth touching the filesystem for this
   * URL?" in a lock and a hash lookup. A collision costs one wasted open, never a wrong image.
   */
  private val present = HashSet<Long>()
  private var indexed = false

  /**
   * What happened since Dart was last told: files stored, with their sizes, and files served. Sent
   * in one message every couple of seconds while anything is happening, not one per tile.
   */
  private val storedSince = ArrayList<Pair<String, Long>>()
  private val readSince = HashSet<String>()
  private var reportScheduled = false
  private const val REPORT_DELAY_MS = 2000L
  /** Lazy: the object is also loaded by plain JVM tests of the naming, where there is no looper. */
  private val main by lazy { Handler(Looper.getMainLooper()) }
  internal var channel: MethodChannel? = null

  // ---------------------------------------------------------------------------
  // Naming — mirrors offline_paths.dart
  // ---------------------------------------------------------------------------

  private fun isSafe(byte: Int): Boolean {
    val value = byte and 0xFF
    return (value in 0x30..0x39) ||
      (value in 0x41..0x5A) ||
      (value in 0x61..0x7A) ||
      value == '.'.code ||
      value == '_'.code ||
      value == '-'.code
  }

  private fun sanitize(value: String): String {
    val bytes = value.toByteArray(Charsets.UTF_8)
    for (i in bytes.indices) {
      if (!isSafe(bytes[i].toInt())) bytes[i] = '-'.code.toByte()
    }
    return String(bytes, Charsets.UTF_8)
  }

  fun fnv1a32(value: String): Int {
    var hash = -0x7EE3623B // 2166136261 as a signed Int
    for (byte in value.toByteArray(Charsets.UTF_8)) {
      hash = (hash xor (byte.toInt() and 0xFF)) * 16777619
    }
    return hash
  }

  fun fnv1a64(value: String): Long {
    var hash = -0x340D631B7BDDDCDBL // 14695981039346656037 as a signed Long
    for (byte in value.toByteArray(Charsets.UTF_8)) {
      hash = (hash xor (byte.toLong() and 0xFF)) * 1099511628211L
    }
    return hash
  }

  /**
   * Filename for a remote URL. Mirrors `offlineBlobName` in Dart and `fileName(for:)` in Swift, and
   * the three must agree byte for byte: Dart names a blob when it downloads it, and this names it
   * when the image path looks for it. A divergence is silent — every image simply falls through to
   * the network and the mirror appears to do nothing.
   *
   * Derived from the URL rather than hashed whole: the path already carries the asset id and the
   * variant, so an asset's files sort together and there is no cryptographic hash on the render
   * path. Scheme and host are excluded, so a file fetched over the LAN endpoint still resolves once
   * endpoint switching moves to the external one; the query folds into a short token, which is how
   * an edited asset lands on a new name rather than serving stale bytes.
   *
   * Three places where the obvious spelling differs from Dart's, each of which would produce a
   * different name for the same URL:
   *
   * - path segments are percent-decoded but `+` is **left alone**, while query values decode `+` to
   *   a space — which is what Dart's `Uri.pathSegments` and `Uri.queryParameters` do, and what
   *   `URLDecoder.decode` would get wrong if used for both;
   * - a repeated query key takes the **last** value, because Dart's `queryParameters` is a map;
   * - and the query is ordered by **UTF-8 bytes**, not by `String.compareTo`, which orders by UTF-16
   *   code unit and agrees only up to the BMP.
   */
  fun fileName(url: String): String? {
    val uri = try {
      URI(url)
    } catch (_: Exception) {
      return null
    }

    val rawPath = uri.rawPath ?: return null
    val segments = rawPath.split('/').filter { it.isNotEmpty() }.map(::decodePath).toMutableList()
    if (segments.firstOrNull() == "api") segments.removeAt(0)
    if (segments.isEmpty()) return null

    var size: String? = null
    val values = LinkedHashMap<String, String>()
    for (pair in (uri.rawQuery ?: "").split('&')) {
      if (pair.isEmpty()) continue
      val split = pair.indexOf('=')
      val key = decodeQuery(if (split < 0) pair else pair.substring(0, split))
      // A valueless `?size` is "" in Dart, which would otherwise name the file differently here.
      val value = if (split < 0) "" else decodeQuery(pair.substring(split + 1))
      if (key == "size") {
        size = value
        continue
      }
      values[key] = value
    }

    val params = values.entries
      .map { "${it.key}=${it.value}" }
      .sortedWith { a, b -> compareUtf8(a, b) }

    val name = StringBuilder(segments.joinToString("_") { sanitize(it) })
    if (size != null) name.append('_').append(sanitize(size))
    name.append(String.format("_%08x", fnv1a32(params.joinToString("&"))))

    val playable = segments.contains("video") || segments.last() == "original"
    return if (playable) "$name.mp4" else name.toString()
  }

  /** Percent-decoding only, as `Uri.pathSegments` does — a `+` in a path is a `+`. */
  private fun decodePath(value: String): String =
    if (value.contains('%')) URLDecoder.decode(value.replace("+", "%2B"), "UTF-8") else value

  /** Percent-decoding and `+` as a space, as `Uri.queryParameters` does. */
  private fun decodeQuery(value: String): String =
    if (value.contains('%') || value.contains('+')) URLDecoder.decode(value, "UTF-8") else value

  private fun compareUtf8(a: String, b: String): Int {
    val left = a.toByteArray(Charsets.UTF_8)
    val right = b.toByteArray(Charsets.UTF_8)
    for (i in 0 until minOf(left.size, right.size)) {
      val diff = (left[i].toInt() and 0xFF) - (right[i].toInt() and 0xFF)
      if (diff != 0) return diff
    }
    return left.size - right.size
  }

  /**
   * Bucket a name falls into. Hashed rather than taken from its first characters, which all read
   * `assets_` and would land in one directory.
   */
  fun bucket(name: String): String = String.format("%02x", fnv1a32(name) and 0xFF)

  private fun pinnedPath(name: String): File? = pinnedRoot?.let { File(File(it, bucket(name)), name) }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /**
   * Creates the store and indexes it, once at launch.
   *
   * The index build walks the whole store, so it runs off the launch path. Until it finishes every
   * lookup is treated as a possible hit and falls through to the filesystem: correct, just not as
   * cheap.
   */
  fun prepare(context: Context) {
    val base = File(context.filesDir, "mirrich_blobs")
    val pinned = File(base, "pinned")
    lock.withLock {
      root = base
      pinnedRoot = pinned
    }
    pinned.mkdirs()

    maintenance.execute {
      // Where older builds kept what browsing fetched, trimmed to a budget of its own. Nothing
      // recorded those files, so they are dropped rather than carried over.
      val legacyCache = File(base, "cache")
      if (legacyCache.exists()) legacyCache.deleteRecursively()

      val hashes = HashSet<Long>()
      for (file in walk(pinned)) hashes.add(fnv1a64(file.name))
      lock.withLock {
        present.addAll(hashes)
        indexed = true
      }
    }
  }

  /**
   * Every regular file under a directory.
   *
   * Hidden files are not skipped: `sanitize` permits a leading `.`, and such a name would then be
   * reported absent by [mightHold]. The Dart integrity pass lists the same directories without
   * skipping anything.
   */
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

  // ---------------------------------------------------------------------------
  // Reading
  // ---------------------------------------------------------------------------

  /** Whether a lookup is worth a filesystem call. Safe to call on any thread. */
  fun mightHold(name: String): Boolean = lock.withLock {
    if (indexed) present.contains(fnv1a64(name)) else true
  }

  /** Runs [body] on the store's own pool, off the thread the image API called from. */
  fun read(body: () -> Unit) {
    io.execute(body)
  }

  /**
   * Stored bytes for a name, or null. A hit counts as a use, which is what eviction orders by.
   *
   * Read straight into the off-heap buffer the image path already speaks, through a mapped channel,
   * so the bytes are not copied through the JVM heap on the way to the decoder.
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

  // ---------------------------------------------------------------------------
  // Writing
  // ---------------------------------------------------------------------------

  /**
   * Keeps bytes that were just fetched for the screen. They land in the store as spares until Dart
   * says otherwise: a selection that wants the same file counts it as its own instead of
   * downloading it again.
   */
  fun store(bytes: ByteArray, name: String) {
    val target = pinnedPath(name) ?: return

    writes.execute {
      // Already here, from the reconciler or an earlier fetch: nothing to add, and nothing new to
      // report.
      if (target.exists()) return@execute
      target.parentFile?.mkdirs()

      // Written aside and renamed into place: a half-written blob that a later read maps decodes as
      // a corrupt image.
      val temporary = File(target.parentFile, "$name.part")
      try {
        temporary.writeBytes(bytes)
        if (!temporary.renameTo(target)) {
          temporary.delete()
          return@execute
        }
      } catch (_: Throwable) {
        temporary.delete()
        return@execute
      }

      lock.withLock {
        present.add(fnv1a64(name))
        storedSince.add(name to bytes.size.toLong())
      }
      scheduleReport()
    }
  }

  /**
   * Records names Dart has just written, so the next lookup for one does not have to discover it by
   * missing first.
   */
  fun noteStored(names: List<String>) {
    lock.withLock { for (name in names) present.add(fnv1a64(name)) }
  }

  /**
   * Forgets names Dart has just deleted — eviction, which runs while browsing and so cannot afford
   * the walk [forgetAll] costs.
   */
  fun noteRemoved(names: List<String>) {
    lock.withLock { for (name in names) present.remove(fnv1a64(name)) }
  }

  /**
   * Forgets everything and rebuilds from a walk.
   *
   * The index only gates whether the filesystem is consulted, so a stale name costs one failed
   * open. Dropping all of it is the honest answer to a bulk delete, since rebuilding is one walk.
   */
  fun forgetAll(context: Context) {
    lock.withLock {
      present.clear()
      indexed = false
    }
    prepare(context)
  }

  // ---------------------------------------------------------------------------
  // Reporting
  // ---------------------------------------------------------------------------

  /**
   * Sends what happened to Dart a little later, so a screenful of tiles is one message. A message
   * nobody receives — Dart not listening yet — is lost, and that is fine: an unreported file is
   * claimed by the reconciler if a selection wants it and swept by the integrity pass if not.
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
 *
 * The reconciler writes into `pinned/` through background_downloader and deletes from it directly,
 * neither passing through this file, so without these a freshly mirrored blob stays invisible until
 * the next launch.
 */
object OfflineStoreChannel {
  fun register(context: Context, messenger: BinaryMessenger) {
    val channel = MethodChannel(messenger, "mirrich/offline_store")
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        // Where `activity` goes: the channel whose Dart side said it listens. Not simply the last
        // one registered — the background worker's engine registers too, and reports sent to it are
        // lost, then sent to nothing once it is gone.
        "listen" -> {
          OfflineStore.channel = channel
          result.success(null)
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

        else -> result.notImplemented()
      }
    }
  }
}
