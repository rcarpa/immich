package app.alextran.immich.images

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import app.alextran.immich.core.HttpClientManager
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * immich-sync fork: downloads the offline store's files natively, so no file bytes pass through Dart. Uses upstream's
 * client, which carries the session, without its response cache.
 *
 * Every file is written to `partial/` first, flushed to disk, checked, and renamed into place, so the store only ever
 * holds complete files. Two lanes:
 *
 * - light (thumbnails, previews): as many at once as Dart asks for, which its adaptive limit decides; never resumed;
 * - heavy (originals, videos): three at a time, queued here, resumed with `Range`/`If-Range` from what an earlier
 *   attempt left, retried a few times on a dropped connection, and checked against the server's SHA-1 when Dart
 *   passes one. While any runs, [OfflineTransferKeepAlive] keeps the process alive in the background.
 *
 * One transfer per file: a second request for a file already downloading joins it, so a Dart engine started after the
 * last one died picks up what is still running instead of writing the same file twice.
 */
object OfflineDownloader {
  private const val TAG = "OfflineDownloader"
  private const val MAX_HEAVY = 3

  /** Dart's adaptive limit stays below this; anything above waits for a thread, before its timeouts start. */
  private const val MAX_LIGHT = 16
  private const val HEAVY_ATTEMPTS = 3
  private const val PARTIAL_MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000
  private const val BUFFER_SIZE = 64 * 1024

  enum class Lane { LIGHT, HEAVY }

  sealed class DownloadResult {
    data class Done(val size: Long) : DownloadResult()

    /** [corrupt]: the server answered but the bytes are not the file. Counted against the file by Dart. */
    data class Failed(val statusCode: Int?, val message: String, val corrupt: Boolean = false) : DownloadResult()
    object Cancelled : DownloadResult()
  }

  private class Transfer(
    val url: String,
    val target: File,
    val lane: Lane,
    val checksum: String?,
    val wifiOnly: Boolean,
  ) {
    /** Dart callers waiting for this file, by request id. Guarded by [lock]. */
    val callbacks = LinkedHashMap<String, (DownloadResult) -> Unit>()

    /** Started after this one stops, when a request came in while it was being cancelled. Guarded by [lock]. */
    var next: Transfer? = null

    /** Owns a thread, or is about to; a waiting heavy transfer does not. Guarded by [lock]. */
    var started = false

    @Volatile
    var cancelled = false

    @Volatile
    var call: Call? = null

    val name: String get() = target.name

    fun cancel() {
      cancelled = true
      call?.cancel()
    }
  }

  /** Why one attempt stopped, when that is not yet the answer. */
  private sealed class Attempt {
    data class Finished(val result: DownloadResult) : Attempt()

    /** What was kept cannot be resumed; start over at once. */
    object Restart : Attempt()

    /** The connection failed; the partial file is kept and the next attempt resumes it. */
    data class Dropped(val message: String) : Attempt()
  }

  private val main by lazy { Handler(Looper.getMainLooper()) }
  private val lock = Any()
  private val transfers = HashMap<String, Transfer>()
  private val byId = HashMap<String, Transfer>()
  private val heavyWaiting = ArrayDeque<Transfer>()
  private var heavyRunning = 0

  private val light = Executors.newFixedThreadPool(MAX_LIGHT, named("mirrich-download"))
  private val heavy = Executors.newFixedThreadPool(MAX_HEAVY, named("mirrich-transfer"))

  @Volatile
  private var appContext: Context? = null

  @Volatile
  private var partialDir: File? = null

  @Volatile
  private var client: OkHttpClient? = null

  private fun named(prefix: String): ThreadFactory {
    val count = AtomicInteger()
    return ThreadFactory { runnable -> Thread(runnable, "$prefix-${count.incrementAndGet()}").apply { isDaemon = true } }
  }

  /** [root] is the store's root; partial files live beside `pinned/`, on the same volume, so the final rename is atomic. */
  fun prepare(context: Context, root: File) {
    if (appContext != null) return
    appContext = context.applicationContext
    val partial = File(root, "partial")
    partialDir = partial
    HttpClientManager.addClientChangedListener { client = null }
    OfflineTransferKeepAlive.prepare(context)

    // What a download left more than a week ago will not be resumed: its file has most likely changed or gone.
    Thread {
      val cutoff = System.currentTimeMillis() - PARTIAL_MAX_AGE_MS
      partial.listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }
    }.apply { isDaemon = true }.start()
  }

  private fun client(): OkHttpClient =
    client ?: HttpClientManager.getClient().newBuilder()
      .cache(null)
      // OkHttp's 10 s defaults are too short for a busy home server; iOS waits 60 s.
      .connectTimeout(30, TimeUnit.SECONDS)
      .readTimeout(60, TimeUnit.SECONDS)
      .build()
      .also { client = it }

  /** Downloads [url] to [path]. [onDone] runs on the main thread, once per [id]. */
  fun download(
    id: String,
    url: String,
    path: String,
    lane: Lane,
    checksum: String?,
    wifiOnly: Boolean,
    onDone: (DownloadResult) -> Unit,
  ) {
    val transfer = Transfer(url, File(path), lane, checksum, wifiOnly)
    synchronized(lock) {
      val existing = transfers[transfer.target.path]
      val joined = when {
        existing == null -> null
        !existing.cancelled -> existing
        // Still stopping: start afresh once it has, so two never write the same partial file.
        else -> existing.next?.takeIf { !it.cancelled }
      }
      if (joined != null) {
        joined.callbacks[id] = onDone
        byId[id] = joined
        return
      }
      // Registered before the transfer can start, so even an instant answer finds its caller.
      transfer.callbacks[id] = onDone
      byId[id] = transfer
      if (existing == null) {
        transfers[transfer.target.path] = transfer
        enqueueLocked(transfer)
      } else {
        existing.next = transfer
      }
    }
    pumpHeavy()
    OfflineTransferKeepAlive.evaluate()
  }

  /** Under [lock]: starts a light transfer, or queues a heavy one for [pumpHeavy]. */
  private fun enqueueLocked(transfer: Transfer) {
    if (transfer.lane == Lane.LIGHT) {
      transfer.started = true
      light.execute { run(transfer) }
    } else {
      heavyWaiting.addLast(transfer)
    }
  }

  private fun pumpHeavy() {
    val starting = ArrayList<Transfer>()
    synchronized(lock) {
      while (heavyRunning < MAX_HEAVY && heavyWaiting.isNotEmpty()) {
        val transfer = heavyWaiting.removeFirst()
        if (transfer.cancelled) {
          if (transfers[transfer.target.path] === transfer) transfers.remove(transfer.target.path)
          continue
        }
        transfer.started = true
        heavyRunning++
        starting.add(transfer)
      }
    }
    for (transfer in starting) {
      heavy.execute {
        try {
          run(transfer)
        } finally {
          synchronized(lock) { heavyRunning-- }
          pumpHeavy()
          OfflineTransferKeepAlive.evaluate()
        }
      }
    }
  }

  /** Stops waiting for [id]. The transfer itself stops once nobody waits for it; its partial file is kept. */
  fun cancel(id: String) {
    val callback = synchronized(lock) {
      val transfer = byId.remove(id) ?: return
      val callback = transfer.callbacks.remove(id)
      if (transfer.callbacks.isEmpty()) cancelLocked(transfer)
      callback
    }
    callback?.let { main.post { it(DownloadResult.Cancelled) } }
    OfflineTransferKeepAlive.evaluate()
  }

  /** Cancels every transfer, including ones nobody waits for any more. Partial files are kept for the next attempt. */
  fun cancelAll() {
    val callbacks = ArrayList<(DownloadResult) -> Unit>()
    synchronized(lock) {
      for (transfer in transfers.values.toList()) {
        transfer.next?.let { callbacks.addAll(it.callbacks.values) }
        transfer.next = null
        callbacks.addAll(transfer.callbacks.values)
        transfer.callbacks.clear()
        cancelLocked(transfer)
      }
      byId.clear()
    }
    for (callback in callbacks) main.post { callback(DownloadResult.Cancelled) }
    OfflineTransferKeepAlive.evaluate()
  }

  /** Under [lock]. A transfer that never started is dropped now; a running one when its thread lets go. */
  private fun cancelLocked(transfer: Transfer) {
    transfer.cancel()
    if (!transfer.started) {
      heavyWaiting.remove(transfer)
      if (transfers[transfer.target.path] === transfer) transfers.remove(transfer.target.path)
    }
  }

  /** Files downloading or waiting to. */
  fun activeCount(): Int = synchronized(lock) { transfers.size }

  fun heavyCount(): Int = synchronized(lock) { heavyRunning + heavyWaiting.size }

  private fun run(transfer: Transfer) {
    val result = try {
      perform(transfer)
    } catch (e: Throwable) {
      if (transfer.cancelled) DownloadResult.Cancelled else DownloadResult.Failed(null, e.toString())
    }
    finish(transfer, result)
  }

  private fun finish(transfer: Transfer, result: DownloadResult) {
    val callbacks = synchronized(lock) {
      val callbacks = transfer.callbacks.values.toList()
      transfer.callbacks.clear()
      byId.entries.removeAll { it.value === transfer }
      if (transfers[transfer.target.path] === transfer) {
        val next = transfer.next
        if (next != null && !next.cancelled) {
          transfers[transfer.target.path] = next
          enqueueLocked(next)
        } else {
          transfers.remove(transfer.target.path)
        }
      }
      callbacks
    }
    // Dart's own log is not in logcat for release builds, so failures are logged here too.
    if (result is DownloadResult.Failed) Log.w(TAG, "Download failed: ${transfer.name}: ${result.message}")
    for (callback in callbacks) main.post { callback(result) }
    pumpHeavy()
    OfflineTransferKeepAlive.evaluate()
  }

  private fun perform(transfer: Transfer): DownloadResult {
    val directory = partialDir ?: return DownloadResult.Failed(null, "Store not prepared")
    directory.mkdirs()
    val partial = File(directory, "${transfer.name}.part")
    val meta = File(directory, "${transfer.name}.meta")
    // A small file is cheaper to fetch again than to resume.
    if (transfer.lane == Lane.LIGHT) {
      partial.delete()
      meta.delete()
    }

    val attempts = if (transfer.lane == Lane.HEAVY) HEAVY_ATTEMPTS else 1
    var lastFailure = "No attempt made"
    for (attempt in 1..attempts) {
      if (transfer.cancelled) return DownloadResult.Cancelled
      if (transfer.wifiOnly && !onWifi()) return DownloadResult.Failed(null, "Waiting for Wi-Fi")

      val outcome = try {
        attempt(transfer, partial, meta)
      } catch (e: IOException) {
        if (transfer.cancelled) return DownloadResult.Cancelled
        Attempt.Dropped(e.toString())
      }

      when (outcome) {
        is Attempt.Finished -> return outcome.result
        Attempt.Restart -> {
          partial.delete()
          meta.delete()
          lastFailure = "The server would not resume the download"
        }

        is Attempt.Dropped -> {
          lastFailure = outcome.message
          if (transfer.lane == Lane.LIGHT) {
            partial.delete()
          } else if (attempt < attempts) {
            // Long enough for a network switch to settle.
            Thread.sleep(2000L * attempt)
          }
        }
      }
    }
    return if (transfer.cancelled) DownloadResult.Cancelled else DownloadResult.Failed(null, lastFailure)
  }

  private fun attempt(transfer: Transfer, partial: File, meta: File): Attempt {
    val resume = if (transfer.lane == Lane.HEAVY) OfflineHttp.readResume(partial, meta) else null

    val request = Request.Builder().url(transfer.url).apply {
      if (resume != null) {
        header("Range", "bytes=${resume.offset}-")
        header("If-Range", resume.validator)
      }
    }.build()
    val call = client().newCall(request)
    transfer.call = call
    if (transfer.cancelled) call.cancel()

    val total: Long? = call.execute().use { response ->
      val append: Boolean
      val expectedTotal: Long?
      when (response.code) {
        200 -> {
          append = false
          // -1 when unknown, or when OkHttp decompresses the body for us.
          expectedTotal = response.body?.contentLength()?.takeIf { it >= 0 }
        }

        206 -> {
          val range = OfflineHttp.parseContentRange(response.header("Content-Range"))
          if (resume == null || range == null || range.start != resume.offset) return Attempt.Restart
          append = true
          expectedTotal = range.total
        }

        // The range is past the end: what was kept is not a prefix of this file.
        416 -> return Attempt.Restart
        else -> return Attempt.Finished(DownloadResult.Failed(response.code, "HTTP ${response.code}"))
      }

      // Not the server's file but a portal or login page: tried again later, never counted against the file.
      val type = response.header("Content-Type")
      if (!OfflineStore.keepsType(type, video = true)) {
        return Attempt.Finished(DownloadResult.Failed(null, "Unexpected content type $type"))
      }

      if (transfer.lane == Lane.HEAVY) {
        val validator = OfflineHttp.validator(response.header("ETag"), response.header("Last-Modified"))
          ?: resume?.validator.takeIf { append }
        if (validator != null) OfflineHttp.writeResume(meta, validator) else meta.delete()
      }

      val body = response.body ?: return Attempt.Dropped("Empty response body")
      FileOutputStream(partial, append).use { output ->
        body.byteStream().use { input ->
          val buffer = ByteArray(BUFFER_SIZE)
          while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            if (transfer.cancelled) throw IOException("Cancelled")
            output.write(buffer, 0, read)
          }
        }
        output.flush()
        // On disk before the rename, or a crash could leave a renamed file whose bytes never landed.
        output.fd.sync()
      }
      expectedTotal
    }

    val length = partial.length()
    if (total != null && length != total) {
      if (length < total) return Attempt.Dropped("Connection closed at $length of $total bytes")
      partial.delete()
      meta.delete()
      return Attempt.Finished(DownloadResult.Failed(null, "Received $length bytes, expected $total", corrupt = true))
    }

    val expected = transfer.checksum
    if (expected != null) {
      if (transfer.cancelled) return Attempt.Finished(DownloadResult.Cancelled)
      val actual = sha1Base64(partial)
      if (actual != expected) {
        partial.delete()
        meta.delete()
        return Attempt.Finished(
          DownloadResult.Failed(null, "Checksum mismatch: expected $expected, got $actual", corrupt = true)
        )
      }
    }

    commit(partial, transfer.target)
    meta.delete()
    OfflineStore.noteStored(listOf(transfer.name))
    return Attempt.Finished(DownloadResult.Done(transfer.target.length()))
  }

  /** Renames a complete, synced file into place, replacing what was there in one step. */
  private fun commit(partial: File, target: File) {
    val directory = target.parentFile ?: throw IOException("No directory for $target")
    directory.mkdirs()
    Files.move(partial.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    // The rename itself, on disk. Best effort: not every filesystem lets a directory be opened.
    try {
      FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
    } catch (_: Exception) {
    }
  }

  private fun sha1Base64(file: File): String {
    val digest = MessageDigest.getInstance("SHA-1")
    file.inputStream().use { input ->
      val buffer = ByteArray(1024 * 1024)
      while (true) {
        val read = input.read(buffer)
        if (read < 0) break
        digest.update(buffer, 0, read)
      }
    }
    return Base64.getEncoder().encodeToString(digest.digest())
  }

  /** Mirrors `hasWifi` in `ConnectivityApiImpl`, which Dart's Wi-Fi only check uses, plus Ethernet. */
  private fun onWifi(): Boolean {
    val context = appContext ?: return true
    val manager = context.getSystemService(ConnectivityManager::class.java) ?: return true
    val capabilities = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
    if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
      capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI_AWARE) ||
      capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    ) return true
    if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
      !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
    ) {
      @Suppress("DEPRECATION")
      return context.applicationContext.getSystemService(WifiManager::class.java)?.isWifiEnabled == true
    }
    return false
  }
}

/** immich-sync fork: the HTTP details of resuming, kept apart so they can be tested without a device. */
internal object OfflineHttp {
  data class ContentRange(val start: Long, val end: Long, val total: Long?)
  data class Resume(val offset: Long, val validator: String)

  /** `bytes 100-199/1000`, or `bytes 100-199/*`. Null for anything else, including `bytes */1000`. */
  fun parseContentRange(header: String?): ContentRange? {
    val match = Regex("""^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$""", RegexOption.IGNORE_CASE).find(header ?: return null)
      ?: return null
    val (start, end, total) = match.destructured
    val first = start.toLongOrNull() ?: return null
    val last = end.toLongOrNull() ?: return null
    if (last < first) return null
    val size = if (total == "*") null else total.toLongOrNull() ?: return null
    if (size != null && last >= size) return null
    return ContentRange(first, last, size)
  }

  /**
   * What `If-Range` sends: a strong ETag, else `Last-Modified`, else a weak ETag. A weak one is not allowed there and
   * a strict server answers with the whole file, which is safe; Express, which Immich serves files with, accepts it.
   */
  fun validator(etag: String?, lastModified: String?): String? {
    val tag = etag?.trim()?.takeIf { it.isNotEmpty() }
    if (tag != null && !tag.startsWith("W/")) return tag
    lastModified?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    return tag
  }

  /** What an earlier attempt left, if it can be resumed: a non-empty partial file and the validator it came with. */
  fun readResume(partial: File, meta: File): Resume? {
    val offset = partial.length()
    val validator = try {
      if (meta.isFile) meta.readText().trim() else null
    } catch (_: IOException) {
      null
    }
    if (offset <= 0 || validator.isNullOrEmpty() || validator.contains('\n')) {
      partial.delete()
      meta.delete()
      return null
    }
    return Resume(offset, validator)
  }

  fun writeResume(meta: File, validator: String) {
    meta.writeText(validator)
  }
}
