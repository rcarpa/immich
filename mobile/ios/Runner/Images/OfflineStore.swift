// immich-sync fork
//
// The one place image bytes live on this device: one region under a single
// root, `pinned/`, written by two parties.
//
//  - The Dart reconciler, through background_downloader, for what the
//    selections ask for.
//  - The image path below, for whatever was looked at. Those files are spares,
//    which Dart evicts least recently used first when the store needs room.
//
// Nothing here deletes anything: deciding what may go needs the selection, and
// that lives in Dart's database. What this side does is report — the files it
// stored, and the files it served — so Dart can write them down. See FORK.md
// §3.4.
//
// The naming here must match lib/utils/offline_paths.dart exactly: if
// they diverge, every read misses silently and the library re-downloads on
// every pass.

import Flutter
import Foundation

/// immich-sync fork: keeps the lookup index in step with Dart, and tells Dart
/// what the image path did.
///
/// The reconciler writes into `pinned/` through background_downloader and
/// deletes from it directly, neither passing through this file, so without these
/// a freshly mirrored blob stays invisible until the next launch.
enum OfflineStoreChannel {
  /// Where `activity` goes: the channel whose Dart side said `listen`. Not
  /// simply the last one registered — the background worker's engine registers
  /// too, and reports sent to it are lost, then sent to nothing once it is gone.
  fileprivate static var channel: FlutterMethodChannel?

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mirrich/offline_store", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "listen":
        Self.channel = channel
        result(nil)
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

  /// Where older builds kept what browsing fetched, trimmed to a budget of its
  /// own. Nothing recorded those files, so they are dropped at launch rather
  /// than carried over.
  private static let legacyCacheRoot = root?.appendingPathComponent("cache", isDirectory: true)

  /// Reads and writes happen here, not on the caller's thread — for the image
  /// API that is the platform main thread.
  static let io = DispatchQueue(label: "app.mirrich.offline-store", qos: .userInitiated, attributes: .concurrent)
  private static let maintenance = DispatchQueue(label: "app.mirrich.offline-store.maintenance", qos: .utility)

  private static let lock = NSLock()
  /// 64-bit name hashes of every file held. Answers "is it worth touching the
  /// filesystem for this URL?" in a lock and a hash lookup. A collision costs
  /// one wasted `open`, never a wrong image.
  private static var present: Set<UInt64> = []
  private static var indexed = false

  /// What happened since Dart was last told: files stored, with their sizes,
  /// and files served. Sent in one message every couple of seconds while
  /// anything is happening, not one per tile.
  private static var storedSince: [(String, Int)] = []
  private static var readSince: Set<String> = []
  private static var reportScheduled = false
  private static let reportDelay: TimeInterval = 2

  // ---------------------------------------------------------------------------
  // Naming — mirrors offline_paths.dart
  // ---------------------------------------------------------------------------

  private static let safeBytes: Set<UInt8> = {
    var set = Set<UInt8>()
    for byte in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(byte) }
    for byte in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(byte) }
    for byte in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(byte) }
    set.formUnion([UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-")])
    return set
  }()

  private static func sanitize(_ value: String) -> String {
    String(decoding: value.utf8.map { safeBytes.contains($0) ? $0 : UInt8(ascii: "-") }, as: UTF8.self)
  }

  static func fnv1a32(_ value: String) -> UInt32 {
    var hash: UInt32 = 2_166_136_261
    for byte in value.utf8 {
      hash = (hash ^ UInt32(byte)) &* 16_777_619
    }
    return hash
  }

  static func fnv1a64(_ value: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return hash
  }

  /// Filename for a remote URL. Mirrors `offlineBlobName` in Dart.
  ///
  /// Derived from the URL rather than hashed whole: the path already carries the
  /// asset id and the variant, so an asset's files sort together and there is no
  /// cryptographic hash on the render path. Scheme and host are excluded, so a
  /// file fetched over the LAN endpoint still resolves once endpoint switching
  /// moves to the external one; the query folds into a short token, which is how
  /// an edited asset lands on a new name rather than serving stale bytes.
  ///
  /// Both sides read the *decoded* path and query, take last-wins for a repeated
  /// key, and order by UTF-8 bytes — each a place where `URLComponents` and
  /// Dart's `Uri` differ by default.
  ///
  /// Playable URLs carry `.mp4` because AVFoundation infers the container from
  /// the extension, and an extensionless file opens as a black frame.
  static func fileName(for url: String) -> String? {
    guard let components = URLComponents(string: url) else { return nil }

    var segments = components.path.split(separator: "/").map(String.init)
    if segments.first == "api" {
      segments.removeFirst()
    }
    guard !segments.isEmpty else { return nil }

    // Last value wins for a repeated key, because Dart's `queryParameters` is a
    // map and collapses them that way.
    var size: String?
    var values: [String: String] = [:]
    for item in components.queryItems ?? [] {
      if item.name == "size" {
        // `?? ""` like every other value: a valueless `?size` is nil here and `""`
        // in Dart, which would name the file differently on each side.
        size = item.value ?? ""
        continue
      }
      values[item.name] = item.value ?? ""
    }
    // Ordered by UTF-8 bytes, not by `String.<`: Swift compares by Unicode
    // canonical equivalence and Dart's `compareTo` by UTF-16 code unit, which
    // agree on ASCII and need not agree beyond it.
    let params = values.map { "\($0.key)=\($0.value)" }
      .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }

    var name = segments.map(sanitize).joined(separator: "_")
    if let size {
      name += "_" + sanitize(size)
    }
    name += String(format: "_%08x", fnv1a32(params.joined(separator: "&")))

    let playable = segments.contains("video") || segments.last == "original"
    return playable ? name + ".mp4" : name
  }

  /// Bucket a name falls into. Hashed rather than taken from its first
  /// characters, which all read `assets_` and would land in one directory.
  static func bucket(for name: String) -> String {
    String(format: "%02x", fnv1a32(name) & 0xFF)
  }

  private static func pinnedPath(_ name: String) -> URL? {
    pinnedRoot?.appendingPathComponent(bucket(for: name), isDirectory: true).appendingPathComponent(name)
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Creates the store and indexes it, once at launch.
  ///
  /// The index build walks the whole store, so it runs off the launch path.
  /// Until it finishes every lookup is treated as a possible hit and falls
  /// through to the filesystem: correct, just not as cheap.
  static func prepare() {
    guard var rootURL = root, let pinnedRoot else { return }

    try? FileManager.default.createDirectory(at: pinnedRoot, withIntermediateDirectories: true)

    // Every blob is re-downloadable and a mirrored library is tens of gigabytes,
    // which without this would all go into the user's iCloud backup.
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? rootURL.setResourceValues(values)

    maintenance.async {
      if let legacyCacheRoot, FileManager.default.fileExists(atPath: legacyCacheRoot.path) {
        try? FileManager.default.removeItem(at: legacyCacheRoot)
      }

      var hashes = Set<UInt64>()
      for name in walk(pinnedRoot) {
        hashes.insert(fnv1a64(name))
      }

      lock.lock()
      present.formUnion(hashes)
      indexed = true
      lock.unlock()
    }
  }

  /// The name of every regular file under a directory.
  ///
  /// No `.skipsHiddenFiles`: `sanitize` permits a leading `.`, and such a name
  /// would then be reported absent by `mightHold`. The Dart integrity pass lists
  /// the same directories without skipping anything.
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

  /// Bytes free on the volume the store is on, as iOS counts them for a write
  /// the user is waiting on — which includes what it would purge from other
  /// apps' caches to make room.
  static func freeSpace() -> Int64? {
    guard let root else { return nil }
    let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  // ---------------------------------------------------------------------------
  // Reading
  // ---------------------------------------------------------------------------

  /// Whether a lookup is worth a filesystem call. Safe to call on any thread.
  static func mightHold(_ name: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return indexed ? present.contains(fnv1a64(name)) : true
  }

  /// Stored bytes for a name, or nil. Memory-mapped: this runs on the image path
  /// for every tile, where copying each blob into the heap is pointless traffic.
  /// Call it from [io]. A hit counts as a use, which is what eviction orders by.
  static func data(name: String) -> Data? {
    guard let file = pinnedPath(name), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
      return nil
    }
    lock.lock()
    readSince.insert(name)
    lock.unlock()
    scheduleReport()
    return data
  }

  // ---------------------------------------------------------------------------
  // Writing
  // ---------------------------------------------------------------------------

  /// Keeps bytes that were just fetched for the screen. They land in the store
  /// as spares until Dart says otherwise: a selection that wants the same file
  /// counts it as its own instead of downloading it again.
  static func store(_ data: Data, name: String) {
    guard let target = pinnedPath(name) else { return }

    io.async(flags: .barrier) {
      // Already here, from the reconciler or an earlier fetch: nothing to add,
      // and nothing new to report.
      guard !FileManager.default.fileExists(atPath: target.path) else { return }

      try? FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

      // `.atomic` writes aside and renames into place: a half-written blob that
      // a later read memory-maps decodes as a corrupt image.
      guard (try? data.write(to: target, options: .atomic)) != nil else { return }

      lock.lock()
      present.insert(fnv1a64(name))
      storedSince.append((name, data.count))
      lock.unlock()
      scheduleReport()
    }
  }

  /// Records a name Dart has just written, so the next lookup for it does not
  /// have to discover it by missing first.
  static func noteStored(_ names: [String]) {
    lock.lock()
    for name in names {
      present.insert(fnv1a64(name))
    }
    lock.unlock()
  }

  /// Forgets names Dart has just deleted — eviction, which runs while browsing
  /// and so cannot afford the walk [forgetAll] costs.
  static func noteRemoved(_ names: [String]) {
    lock.lock()
    for name in names {
      present.remove(fnv1a64(name))
    }
    lock.unlock()
  }

  /// Forgets everything and rebuilds from a walk.
  ///
  /// The index only gates whether the filesystem is consulted, so a stale name
  /// costs one failed `open`. Dropping all of it is the honest answer to a bulk
  /// delete, since rebuilding is one walk.
  static func forgetAll() {
    lock.lock()
    present.removeAll()
    indexed = false
    lock.unlock()
    prepare()
  }

  // ---------------------------------------------------------------------------
  // Reporting
  // ---------------------------------------------------------------------------

  /// Sends what happened to Dart a little later, so a screenful of tiles is one
  /// message. A message nobody receives — Dart not listening yet — is lost, and
  /// that is fine: an unreported file is claimed by the reconciler if a
  /// selection wants it and swept by the integrity pass if not.
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
