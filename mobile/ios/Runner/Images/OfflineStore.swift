// immich-sync fork: the offline store's files, under `pinned/`. The Dart reconciler has `OfflineDownloader` below write
// what selections ask for, and the image path keeps whatever was looked at, as spares. Nothing here
// deletes: that needs the selection, which lives in Dart. This side reports what it stored and served so Dart can
// record it.
//
// File names come from the native core (`offline_name.rs`), shared with Dart and Kotlin.

import CryptoKit
import Flutter
import Foundation
import UIKit

/// immich-sync fork: keeps the lookup index in step with Dart, and tells Dart what the image path did.
enum OfflineStoreChannel {
  /// The app engine's channel, once its Dart side called `listen`.
  fileprivate static var channel: FlutterMethodChannel?

  /// The app's own engine. The background worker's engine registers the same channel, and if it took the reports they
  /// would stop reaching the app until it restarted. Set and read on the main thread.
  private static var appMessenger: AnyObject?

  static func registerAppEngine(messenger: FlutterBinaryMessenger) {
    appMessenger = messenger
  }

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mirrich/offline_store", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "listen":
        // Only the app's engine is told what the image path did.
        let accepted = (messenger as AnyObject) === appMessenger
        if accepted {
          Self.channel = channel
        }
        result(accepted)
      case "noteStored":
        OfflineStore.noteStored(call.arguments as? [String] ?? [])
        result(nil)
      case "noteRemoved":
        OfflineStore.noteRemoved(call.arguments as? [String] ?? [])
        result(nil)
      case "forgetAll":
        OfflineStore.forgetAll()
        result(nil)
      case "freeSpace":
        result(OfflineStore.freeSpace())
      case "download":
        guard let args = call.arguments as? [String: Any], let id = args["id"] as? String,
              let url = args["url"] as? String, let path = args["path"] as? String
        else {
          return result(FlutterError(code: "network", message: "Invalid arguments", details: nil))
        }
        OfflineDownloader.shared.download(
          id: id,
          url: url,
          path: path,
          heavy: args["lane"] as? String == "heavy",
          checksum: args["checksum"] as? String,
          wifiOnly: args["wifiOnly"] as? Bool ?? false,
          completion: result)
      case "cancelDownload":
        OfflineDownloader.shared.cancel(id: call.arguments as? String ?? "")
        result(nil)
      case "cancelAll":
        OfflineDownloader.shared.cancelAll()
        result(nil)
      case "keepAlive":
        // iOS cannot keep the app running; large files carry on in the background session instead.
        result(false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

enum OfflineStore {
  /// Application Support, not Caches: iOS purges Caches under storage pressure.
  static let root: URL? = {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    return base.appendingPathComponent("mirrich_blobs", isDirectory: true)
  }()

  private static let pinnedRoot = root?.appendingPathComponent("pinned", isDirectory: true)

  /// Downloads in progress, beside `pinned/` on the same volume so the final rename is atomic.
  static let partialRoot = root?.appendingPathComponent("partial", isDirectory: true)

  /// Where older builds kept browsed files. Nothing recorded them, so they are dropped at launch.
  private static let legacyCacheRoot = root?.appendingPathComponent("cache", isDirectory: true)

  /// Reads and writes run here, off the platform main thread.
  static let io = DispatchQueue(label: "app.mirrich.offline-store", qos: .userInitiated, attributes: .concurrent)
  private static let maintenance = DispatchQueue(label: "app.mirrich.offline-store.maintenance", qos: .utility)

  private static let lock = NSLock()
  /// 64-bit name hashes of every stored file, so a miss costs no filesystem access. A collision costs one wasted /
  /// `open`, never a wrong image.
  private static var present: Set<UInt64> = []
  private static var indexed = false

  /// Files stored (with sizes) and served since Dart was last told, sent every couple of seconds.
  private static var storedSince: [(String, Int)] = []
  private static var readSince: Set<String> = []
  private static var reportScheduled = false
  private static let reportDelay: TimeInterval = 2

  // MARK: - Naming

  /// Name hash from the native core; 0 without it, when nothing can be named, stored or read anyway.
  static func nameHash(_ name: String) -> UInt64 {
    NativeCore.offlineNameHash(name) ?? 0
  }

  /// Filename for a remote URL, from the native core, which Dart and Kotlin name files with too. Playable files end in
  /// `.mp4`, which AVFoundation needs to open them.
  static func fileName(for url: String) -> String? {
    NativeCore.offlineName(url)
  }

  /// Bucket a name falls into, or nil without the native core.
  static func bucket(for name: String) -> String? {
    NativeCore.offlineBucket(name).map { String(format: "%02x", $0) }
  }

  fileprivate static func pinnedPath(_ name: String) -> URL? {
    guard let pinnedRoot, let bucket = bucket(for: name) else { return nil }
    return pinnedRoot.appendingPathComponent(bucket, isDirectory: true).appendingPathComponent(name)
  }

  // MARK: - Lifecycle

  /// Creates the store and indexes it, once at launch. The index is built off the launch path; until then every
  /// lookup / checks the filesystem.
  static func prepare() {
    guard var rootURL = root, let pinnedRoot else { return }

    // Without the core no file can be named, so every read misses and nothing is stored: say so once.
    if !NativeCore.hasOfflineNaming {
      NSLog("[OfflineStore] The native core's naming is unavailable; offline copies cannot be read or stored")
    }

    try? FileManager.default.createDirectory(at: pinnedRoot, withIntermediateDirectories: true)

    // Every file can be downloaded again, so keep the store out of iCloud backups.
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? rootURL.setResourceValues(values)

    // Reconnects to the background session, which may have finished files while the app was not running.
    OfflineDownloader.shared.activate()

    maintenance.async {
      if let legacyCacheRoot, FileManager.default.fileExists(atPath: legacyCacheRoot.path) {
        try? FileManager.default.removeItem(at: legacyCacheRoot)
      }

      var hashes = Set<UInt64>()
      for name in walk(pinnedRoot) {
        hashes.insert(nameHash(name))
      }

      lock.lock()
      present.formUnion(hashes)
      indexed = true
      lock.unlock()
    }
  }

  /// The name of every regular file under a directory. Hidden files included, as in the Dart integrity pass.
  private static func walk(_ directory: URL) -> [String] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: keys, options: [])
    else { return [] }

    var found: [String] = []
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
      found.append(url.lastPathComponent)
    }
    return found
  }

  /// Bytes free for an important write, which includes what iOS would purge from other apps' caches.
  static func freeSpace() -> Int64? {
    guard let root else { return nil }
    let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  // MARK: - Reading

  /// Whether a lookup is worth a filesystem call. Safe to call on any thread.
  static func mightHold(_ name: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return indexed ? present.contains(nameHash(name)) : true
  }

  /// Stored bytes for a name, or nil. Memory-mapped, since this runs for every tile. Call it from [io]. A hit counts
  /// as / a use.
  static func data(name: String) -> Data? {
    // An empty file is what a crash can leave: a miss, so the image path fetches it again and writes over it.
    guard let file = pinnedPath(name), let data = try? Data(contentsOf: file, options: .mappedIfSafe), !data.isEmpty
    else {
      return nil
    }
    lock.lock()
    readSince.insert(name)
    lock.unlock()
    scheduleReport()
    return data
  }

  private static let jxlContainer: [UInt8] = [0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]

  /// Whether stored bytes are JPEG XL, told from the signature since no content type is kept.
  static func isJxl(_ data: Data) -> Bool {
    data.starts(with: [0xFF, 0x0A]) || data.starts(with: jxlContainer)
  }

  // MARK: - Writing

  /// Whether a response's bytes may be kept: an image (or a video, for the queue), or a type the server did not name. A
  /// login page or portal that answers with 200 is not, since a kept file is served ahead of the network from then on.
  static func keepsType(_ mimeType: String?, video: Bool = false) -> Bool {
    guard let type = mimeType?.lowercased(), !type.isEmpty else { return true }
    return type.hasPrefix("image/") || type == "application/octet-stream" || (video && type.hasPrefix("video/"))
  }

  /// Keeps bytes just fetched for the screen. They are spares until a selection wants the same file.
  static func store(_ data: Data, name: String) {
    guard let target = pinnedPath(name) else { return }

    io.async(flags: .barrier) {
      // Already here: nothing to add or report. An empty file is what a crash can leave, so it is replaced.
      let existing = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
      guard (existing ?? 0) == 0 else { return }

      try? FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

      // Atomic, so a half-written file is never memory-mapped.
      guard (try? data.write(to: target, options: .atomic)) != nil else { return }

      lock.lock()
      present.insert(nameHash(name))
      storedSince.append((name, data.count))
      lock.unlock()
      scheduleReport()
    }
  }

  /// Records a name Dart has just written, so the next lookup finds it.
  static func noteStored(_ names: [String]) {
    lock.lock()
    for name in names {
      present.insert(nameHash(name))
    }
    lock.unlock()
  }

  /// Forgets names Dart has just deleted; cheaper than [forgetAll].
  static func noteRemoved(_ names: [String]) {
    lock.lock()
    for name in names {
      present.remove(nameHash(name))
    }
    lock.unlock()
  }

  /// Forgets everything and rebuilds from a walk, after a bulk delete.
  static func forgetAll() {
    lock.lock()
    present.removeAll()
    indexed = false
    lock.unlock()
    prepare()
  }

  // MARK: - Reporting

  /// Sends what happened to Dart a little later, so a screenful of tiles is one message. A report nobody receives is
  /// harmless: the reconciler or the integrity pass catches up.
  private static func scheduleReport() {
    lock.lock()
    let first = !reportScheduled
    reportScheduled = true
    lock.unlock()
    guard first else { return }

    DispatchQueue.main.asyncAfter(deadline: .now() + reportDelay) {
      lock.lock()
      let stored = storedSince
      let read = Array(readSince)
      storedSince = []
      readSince = []
      reportScheduled = false
      lock.unlock()
      guard !stored.isEmpty || !read.isEmpty else { return }

      OfflineStoreChannel.channel?.invokeMethod(
        "activity",
        arguments: [
          "stored": stored.map { [$0.0, $0.1] as [Any] },
          "read": read,
        ])
    }
  }
}


/// immich-sync fork: downloads the offline store's files natively, so no file bytes pass through Dart. Every file is
/// staged under `partial/`, flushed to disk, checked and renamed into place, so `pinned/` only ever holds complete
/// files. Two lanes:
///
/// - light (thumbnails, previews): upstream's session, as many at once as Dart's adaptive limit asks for;
/// - heavy (originals, videos): a background session, which the system carries on while the app is suspended or even
///   terminated, three at a time. A stopped download keeps its resume data and the next attempt continues it; a
///   finished one is checked against the server's SHA-1 when Dart passes one.
///
/// One transfer per file: a second request for a file already downloading joins it, which is also how a fresh launch
/// picks up what the background session was still doing.
final class OfflineDownloader: NSObject {
  static let shared = OfflineDownloader()

  private static let sessionIdentifier = "app.mirrich.offline-transfers"
  private static let maxHeavy = 3
  private static let partialMaxAge: TimeInterval = 7 * 24 * 60 * 60

  private final class Transfer {
    let name: String
    let target: URL
    let heavy: Bool
    let checksum: String?
    var waiters: [String: FlutterResult] = [:]
    var task: URLSessionTask?
    var cancelled = false

    init(name: String, target: URL, heavy: Bool, checksum: String?) {
      self.name = name
      self.target = target
      self.heavy = heavy
      self.checksum = checksum
    }
  }

  private enum Outcome {
    case done(Int64)
    case http(Int)
    case network(String)
    case corrupt(String)
    case cancelled

    var flutterValue: Any? {
      switch self {
      case .done(let size): return size
      case .http(let status): return FlutterError(code: "http", message: "HTTP \(status)", details: status)
      case .network(let message): return FlutterError(code: "network", message: message, details: nil)
      case .corrupt(let message): return FlutterError(code: "integrity", message: message, details: nil)
      case .cancelled: return FlutterError(code: "cancelled", message: nil, details: nil)
      }
    }
  }

  private let lock = NSLock()
  private var transfers: [String: Transfer] = [:]
  private var byId: [String: Transfer] = [:]
  private var byTask: [Int: Transfer] = [:]
  /// What a heavy task downloaded, moved aside before the system deletes it, until the task completes.
  private var staged: [Int: URL] = [:]
  private var restored = false
  private var deferred: [() -> Void] = []
  private var activated = false

  /// Background launches: the system's handler, called once every event is handled and every file is in place.
  private var eventsCompletion: (() -> Void)?
  private var eventsFinished = false
  private var processing = 0

  /// Checks and moves heavy files off the session's delegate queue.
  private let work = DispatchQueue(label: "app.mirrich.offline-transfers.work", qos: .utility)

  private lazy var background: URLSession = {
    let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
    // User-initiated: run now rather than at the system's convenience. Tasks created in the background are
    // discretionary regardless.
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    config.httpMaximumConnectionsPerHost = Self.maxHeavy
    config.httpCookieStorage = URLSessionManager.cookieStorage
    config.httpAdditionalHeaders = ["User-Agent": URLSessionManager.userAgent]
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 60
    // A file that could not be fetched in a day is better asked for again by the queue.
    config.timeoutIntervalForResource = 24 * 60 * 60
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "app.mirrich.offline-transfers.delegate"
    return URLSession(configuration: config, delegate: self, delegateQueue: queue)
  }()

  // MARK: - Lifecycle

  /// Creates the background session once, and picks up the tasks it still has. Requests wait until that is done, so a
  /// file the session is already fetching is joined rather than fetched twice.
  func activate() {
    lock.lock()
    let first = !activated
    activated = true
    lock.unlock()
    guard first else { return }

    work.async { Self.sweepPartials() }

    background.getAllTasks { tasks in
      self.lock.lock()
      for task in tasks {
        // Already met through a delegate callback that arrived first.
        if self.byTask[task.taskIdentifier] != nil {
          continue
        }
        guard let info = Self.decode(task.taskDescription), let target = OfflineStore.pinnedPath(info.name) else {
          task.cancel()
          continue
        }
        let transfer = Transfer(name: info.name, target: target, heavy: true, checksum: info.checksum)
        transfer.task = task
        self.transfers[info.name] = transfer
        self.byTask[task.taskIdentifier] = transfer
      }
      self.restored = true
      let deferred = self.deferred
      self.deferred = []
      self.lock.unlock()
      deferred.forEach { $0() }
    }
  }

  /// From `AppDelegate`: the system launched the app to deliver this session's events.
  func handleEvents(forSession identifier: String, completion: @escaping () -> Void) -> Bool {
    guard identifier == Self.sessionIdentifier else { return false }
    lock.lock()
    eventsCompletion = completion
    eventsFinished = false
    lock.unlock()
    activate()
    return true
  }

  private func finishEventsIfDone() {
    lock.lock()
    let completion = eventsFinished && processing == 0 ? eventsCompletion : nil
    if completion != nil {
      eventsCompletion = nil
      eventsFinished = false
    }
    lock.unlock()
    if let completion {
      DispatchQueue.main.async(execute: completion)
    }
  }

  // MARK: - Requests

  /// Downloads [url] to [path]. [completion] gets the size, or a FlutterError coded `http` (status in details),
  /// `network`, `integrity` or `cancelled`, on the main thread.
  func download(
    id: String, url: String, path: String, heavy: Bool, checksum: String?, wifiOnly: Bool,
    completion: @escaping FlutterResult
  ) {
    lock.lock()
    if !restored {
      deferred.append { [self] in
        download(id: id, url: url, path: path, heavy: heavy, checksum: checksum, wifiOnly: wifiOnly, completion: completion)
      }
      lock.unlock()
      return
    }

    guard let parsed = URL(string: url) else {
      lock.unlock()
      return completion(Outcome.network("Invalid URL").flutterValue)
    }
    let target = URL(fileURLWithPath: path)
    let name = target.lastPathComponent

    if let existing = transfers[name], !existing.cancelled {
      existing.waiters[id] = completion
      byId[id] = existing
      lock.unlock()
      return
    }

    let transfer = Transfer(name: name, target: target, heavy: heavy, checksum: checksum)
    transfer.waiters[id] = completion
    transfers[name] = transfer
    byId[id] = transfer

    var request = URLRequest(url: parsed)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    // Wi-Fi only: a background task waits for Wi-Fi rather than failing.
    request.allowsCellularAccess = !wifiOnly
    request.allowsExpensiveNetworkAccess = !wifiOnly
    for (key, value) in UserDefaults.group.dictionary(forKey: HEADERS_KEY) as? [String: String] ?? [:] {
      request.setValue(value, forHTTPHeaderField: key)
    }

    let task: URLSessionTask
    if heavy {
      let downloadTask: URLSessionDownloadTask
      if let resumeData = Self.takeResumeData(name: name, url: url) {
        downloadTask = background.downloadTask(withResumeData: resumeData)
      } else {
        downloadTask = background.downloadTask(with: request)
      }
      downloadTask.taskDescription = Self.encode(name: name, checksum: checksum)
      byTask[downloadTask.taskIdentifier] = transfer
      task = downloadTask
    } else {
      task = URLSessionManager.shared.session.downloadTask(with: request) { [weak self] temp, response, error in
        guard let self else { return }
        self.finish(transfer, self.lightOutcome(transfer, temp: temp, response: response, error: error))
      }
    }
    transfer.task = task
    lock.unlock()
    task.resume()
  }

  /// Stops waiting for [id]. The transfer stops once nobody waits for it; a heavy one keeps its resume data.
  func cancel(id: String) {
    lock.lock()
    guard let transfer = byId.removeValue(forKey: id) else {
      lock.unlock()
      return
    }
    let waiter = transfer.waiters.removeValue(forKey: id)
    let stop = transfer.waiters.isEmpty
    if stop {
      transfer.cancelled = true
    }
    lock.unlock()
    if stop {
      stopTask(of: transfer)
    }
    if let waiter {
      DispatchQueue.main.async { waiter(Outcome.cancelled.flutterValue) }
    }
  }

  /// Cancels every transfer, including ones nobody waits for any more, such as those found at launch.
  func cancelAll() {
    lock.lock()
    let all = Array(transfers.values)
    var waiters: [FlutterResult] = []
    for transfer in all {
      waiters.append(contentsOf: transfer.waiters.values)
      transfer.waiters = [:]
      transfer.cancelled = true
    }
    byId = [:]
    lock.unlock()
    all.forEach(stopTask(of:))
    for waiter in waiters {
      DispatchQueue.main.async { waiter(Outcome.cancelled.flutterValue) }
    }
  }

  private func stopTask(of transfer: Transfer) {
    guard let task = transfer.task else { return }
    if transfer.heavy, let downloadTask = task as? URLSessionDownloadTask {
      let url = task.originalRequest?.url?.absoluteString
      downloadTask.cancel(byProducingResumeData: { data in
        if let data, let url {
          Self.saveResumeData(data, name: transfer.name, url: url)
        }
      })
    } else {
      task.cancel()
    }
  }

  private func finish(_ transfer: Transfer, _ outcome: Outcome) {
    lock.lock()
    let waiters = Array(transfer.waiters.values)
    transfer.waiters = [:]
    if transfers[transfer.name] === transfer {
      transfers.removeValue(forKey: transfer.name)
    }
    byId = byId.filter { $0.value !== transfer }
    if let task = transfer.task {
      byTask.removeValue(forKey: task.taskIdentifier)
    }
    lock.unlock()

    if case .done = outcome {
      OfflineStore.noteStored([transfer.name])
    } else if case .cancelled = outcome {
    } else {
      NSLog("[OfflineDownloader] Download failed: \(transfer.name): \(String(describing: outcome.flutterValue))")
    }
    let value = outcome.flutterValue
    for waiter in waiters {
      DispatchQueue.main.async { waiter(value) }
    }
  }

  // MARK: - Light lane

  /// Runs in the completion handler, before the system deletes [temp].
  private func lightOutcome(_ transfer: Transfer, temp: URL?, response: URLResponse?, error: Error?) -> Outcome {
    if let error = error as? URLError, error.code == .cancelled {
      return .cancelled
    }
    if let error {
      return .network(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
      return .network("No response")
    }
    guard http.statusCode == 200 else {
      return .http(http.statusCode)
    }
    guard let temp else {
      return .network("No file")
    }
    do {
      let staging = try Self.stage(temp, name: transfer.name)
      return try Self.verifyAndCommit(staging, response: http, checksum: transfer.checksum, target: transfer.target)
    } catch {
      return .network(error.localizedDescription)
    }
  }

  // MARK: - Files

  private static func stage(_ location: URL, name: String) throws -> URL {
    guard let partialRoot = OfflineStore.partialRoot else {
      throw CocoaError(.fileNoSuchFile)
    }
    let manager = FileManager.default
    try manager.createDirectory(at: partialRoot, withIntermediateDirectories: true)
    let staging = partialRoot.appendingPathComponent("\(name).\(UUID().uuidString).download")
    try manager.moveItem(at: location, to: staging)
    return staging
  }

  /// Checks a downloaded file against what the response promised and the checksum, then renames it into place.
  /// Removes the staged file whatever happens.
  private static func verifyAndCommit(_ staging: URL, response: HTTPURLResponse, checksum: String?, target: URL) throws
    -> Outcome
  {
    let manager = FileManager.default
    defer { try? manager.removeItem(at: staging) }

    // Not the server's file but a portal or login page: tried again later, never counted against the file.
    guard OfflineStore.keepsType(response.mimeType, video: true) else {
      return .network("Unexpected content type \(response.mimeType ?? "")")
    }

    let size = (try manager.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value ?? -1
    if let expected = expectedSize(response), size != expected {
      return .corrupt("Received \(size) bytes, expected \(expected)")
    }
    if let checksum {
      let actual = try sha1Base64(staging)
      if actual != checksum {
        return .corrupt("Checksum mismatch: expected \(checksum), got \(actual)")
      }
    }

    // On disk before the rename, or a crash could leave a renamed file whose bytes never landed.
    let handle = try FileHandle(forUpdating: staging)
    try handle.synchronize()
    try handle.close()

    let directory = target.deletingLastPathComponent()
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    // rename(2) replaces the target in one step; FileManager's move refuses an existing one.
    if rename(staging.path, target.path) != 0 {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let fd = open(directory.path, O_RDONLY)
    if fd >= 0 {
      fsync(fd)
      close(fd)
    }
    return .done(size)
  }

  /// The full size the response describes: the total of a `206`'s range, or a `200`'s length. Unknown when the body
  /// was encoded, since the length then counts the encoded bytes.
  private static func expectedSize(_ response: HTTPURLResponse) -> Int64? {
    if response.value(forHTTPHeaderField: "Content-Encoding").map({ !$0.isEmpty && $0 != "identity" }) == true {
      return nil
    }
    if response.statusCode == 206 {
      guard let range = response.value(forHTTPHeaderField: "Content-Range"),
            let slash = range.lastIndex(of: "/")
      else { return nil }
      return Int64(range[range.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
    return response.expectedContentLength > 0 ? response.expectedContentLength : nil
  }

  private static func sha1Base64(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = Insecure.SHA1()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return Data(hasher.finalize()).base64EncodedString()
  }

  private static func sweepPartials() {
    guard let partialRoot = OfflineStore.partialRoot,
          let files = try? FileManager.default.contentsOfDirectory(
            at: partialRoot, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    let cutoff = Date().addingTimeInterval(-partialMaxAge)
    for file in files {
      let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      // Staged files belong to a running check; only old ones are leftovers.
      if let modified, modified < cutoff {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }

  // MARK: - Resume data

  private static func resumeURL(_ name: String) -> URL? {
    OfflineStore.partialRoot?.appendingPathComponent("\(name).resume")
  }

  /// Kept with the URL it was for: resume data replays its own request, so after a switch between the LAN and the
  /// external address it would ask a server that can no longer be reached.
  private static func saveResumeData(_ data: Data, name: String, url: String) {
    guard let file = resumeURL(name), let partialRoot = OfflineStore.partialRoot else { return }
    let record: [String: Any] = ["url": url, "data": data]
    guard let encoded = try? PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
    else { return }
    try? FileManager.default.createDirectory(at: partialRoot, withIntermediateDirectories: true)
    try? encoded.write(to: file, options: .atomic)
  }

  /// Used once: a resumed task that fails again produces fresh resume data, or none.
  private static func takeResumeData(name: String, url: String) -> Data? {
    guard let file = resumeURL(name), let encoded = try? Data(contentsOf: file) else { return nil }
    try? FileManager.default.removeItem(at: file)
    guard let record = try? PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any],
          record["url"] as? String == url
    else { return nil }
    return record["data"] as? Data
  }

  // MARK: - Task description

  private struct TaskInfo {
    let name: String
    let checksum: String?
  }

  private static func encode(name: String, checksum: String?) -> String? {
    var object: [String: String] = ["name": name]
    object["checksum"] = checksum
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func decode(_ description: String?) -> TaskInfo? {
    guard let data = description?.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let name = object["name"], !name.isEmpty
    else { return nil }
    return TaskInfo(name: name, checksum: object["checksum"])
  }

  private func transfer(for task: URLSessionTask) -> Transfer? {
    lock.lock()
    defer { lock.unlock() }
    if let transfer = byTask[task.taskIdentifier] {
      return transfer
    }
    // A task from before this launch that `activate` has not reached yet.
    guard let info = Self.decode(task.taskDescription), let target = OfflineStore.pinnedPath(info.name) else {
      return nil
    }
    let transfer = transfers[info.name].flatMap { $0.task === task ? $0 : nil }
      ?? Transfer(name: info.name, target: target, heavy: true, checksum: info.checksum)
    transfer.task = task
    byTask[task.taskIdentifier] = transfer
    if transfers[info.name] == nil {
      transfers[info.name] = transfer
    }
    return transfer
  }
}

// MARK: - Background session delegate

extension OfflineDownloader: URLSessionDownloadDelegate {
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
  ) {
    guard let transfer = transfer(for: downloadTask) else { return }
    // The system deletes [location] when this returns, so it is moved now and checked once the task completes.
    guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206
    else { return }
    if let staging = try? Self.stage(location, name: transfer.name) {
      lock.lock()
      staged[downloadTask.taskIdentifier] = staging
      lock.unlock()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let transfer = transfer(for: task) else { return }
    lock.lock()
    let staging = staged.removeValue(forKey: task.taskIdentifier)
    lock.unlock()

    if let error {
      if let staging {
        try? FileManager.default.removeItem(at: staging)
      }
      let nsError = error as NSError
      if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
         let url = task.originalRequest?.url?.absoluteString
      {
        Self.saveResumeData(data, name: transfer.name, url: url)
      }
      let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
      finish(transfer, cancelled ? .cancelled : .network(error.localizedDescription))
      return
    }

    guard let http = task.response as? HTTPURLResponse else {
      finish(transfer, .network("No response"))
      return
    }
    guard http.statusCode == 200 || http.statusCode == 206 else {
      finish(transfer, .http(http.statusCode))
      return
    }
    guard let staging else {
      finish(transfer, .network("The downloaded file could not be kept"))
      return
    }

    // Hashing a large video takes seconds; ask for the time to finish it if the app is about to be suspended.
    lock.lock()
    processing += 1
    lock.unlock()
    var assertion = UIBackgroundTaskIdentifier.invalid
    assertion = UIApplication.shared.beginBackgroundTask(withName: "Mirrich offline file") {
      UIApplication.shared.endBackgroundTask(assertion)
      assertion = .invalid
    }
    work.async {
      let outcome: Outcome
      do {
        outcome = try Self.verifyAndCommit(staging, response: http, checksum: transfer.checksum, target: transfer.target)
      } catch {
        outcome = .network(error.localizedDescription)
      }
      self.finish(transfer, outcome)
      self.lock.lock()
      self.processing -= 1
      self.lock.unlock()
      self.finishEventsIfDone()
      if assertion != .invalid {
        UIApplication.shared.endBackgroundTask(assertion)
      }
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    lock.lock()
    eventsFinished = true
    lock.unlock()
    finishEventsIfDone()
  }

  // Upstream's handling: client certificates (mTLS) and basic auth in the server URL.
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    URLSessionManager.shared.delegate.handleChallenge(session, challenge, completionHandler)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    URLSessionManager.shared.delegate.handleChallenge(session, challenge, completionHandler, task: task)
  }
}

/// immich-sync fork: hands background-session launches to [OfflineDownloader]. A plugin rather than an `AppDelegate`
/// override, since Flutter's app delegate forwards these events to plugins and does not expose its own to subclasses.
final class OfflineTransfersPlugin: NSObject, FlutterPlugin {
  private static let instance = OfflineTransfersPlugin()

  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.addApplicationDelegate(instance)
  }

  func application(
    _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) -> Bool {
    OfflineDownloader.shared.handleEvents(forSession: identifier, completion: completionHandler)
  }
}
