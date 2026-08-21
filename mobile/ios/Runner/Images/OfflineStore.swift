// immich-sync fork
//
// The one place image bytes live on this device. Two regions under a single
// root, so there is one directory to size, one to clear, and no second disk
// cache holding a redundant copy of the same photo:
//
//  - `pinned/` — what the user asked to keep, written by the Dart reconciler
//    through background_downloader and never evicted from here.
//  - `cache/` — what happened to be looked at, written by the image path below,
//    trimmed here to a byte budget, and claimed by the reconciler when it turns
//    out to be wanted rather than fetched a second time.
//
// The naming here must match lib/utils/offline_paths.dart exactly: if
// they diverge, every read misses silently and the library re-downloads on
// every pass. See mobile/FORK.md.

import Flutter
import Foundation

/// immich-sync fork: lets Dart keep the lookup index in step.
///
/// The reconciler writes into `pinned/` through background_downloader and
/// deletes from it directly, neither passing through this file, so without these
/// a freshly mirrored blob stays invisible until the next launch.
enum OfflineStoreChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mirrich/offline_store", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "noteStored":
        OfflineStore.noteStored(call.arguments as? [String] ?? [])
        result(nil)
      case "notePromoted":
        OfflineStore.notePromoted(bytes: (call.arguments as? NSNumber)?.int64Value ?? 0)
        result(nil)
      case "forgetAll":
        OfflineStore.forgetAll()
        result(nil)
      case "cacheSize":
        result(OfflineStore.cacheSize())
      case "setCacheBudget":
        OfflineStore.setCacheBudget((call.arguments as? NSNumber)?.uint64Value ?? 0)
        result(nil)
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
  private static let cacheRoot = root?.appendingPathComponent("cache", isDirectory: true)

  /// How much the opportunistic region may hold. Dart owns the value and pushes
  /// it at launch and on every change; this default holds until it does. Zero
  /// means keep nothing — browsing then writes no blobs at all.
  private static var cacheBudget: UInt64 = 256 * 1024 * 1024

  /// Sets the budget and trims down to it straight away, so lowering it takes
  /// effect while the user is still looking at the screen that changed it.
  static func setCacheBudget(_ bytes: UInt64) {
    lock.lock()
    cacheBudget = bytes
    lock.unlock()
    if bytes == 0 {
      clearCache()
      return
    }
    trimCacheIfNeeded()
  }

  /// Reads and writes happen here, not on the caller's thread — for the image
  /// API that is the platform main thread.
  static let io = DispatchQueue(label: "app.mirrich.offline-store", qos: .userInitiated, attributes: .concurrent)
  private static let maintenance = DispatchQueue(label: "app.mirrich.offline-store.maintenance", qos: .utility)

  private static let lock = NSLock()
  /// 64-bit name hashes of every file held, in either region. Answers "is it
  /// worth touching the filesystem for this URL?" in a lock and a hash lookup.
  /// A collision costs one wasted `open`, never a wrong image.
  private static var present: Set<UInt64> = []
  private static var indexed = false
  private static var cacheBytes: UInt64 = 0
  private static var trimming = false

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

  private static func cachePath(_ name: String) -> URL? {
    cacheRoot?.appendingPathComponent(bucket(for: name), isDirectory: true).appendingPathComponent(name)
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
    guard var rootURL = root, let pinnedRoot, let cacheRoot else { return }

    try? FileManager.default.createDirectory(at: pinnedRoot, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

    // Every blob is re-downloadable and a mirrored library is tens of gigabytes,
    // which without this would all go into the user's iCloud backup.
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? rootURL.setResourceValues(values)

    maintenance.async {
      var hashes = Set<UInt64>()
      var bytes: UInt64 = 0
      for (region, isCache) in [(pinnedRoot, false), (cacheRoot, true)] {
        for (name, size, _) in walk(region) {
          hashes.insert(fnv1a64(name))
          if isCache {
            bytes += size
          }
        }
      }

      lock.lock()
      present.formUnion(hashes)
      cacheBytes = bytes
      indexed = true
      lock.unlock()

      trimCacheIfNeeded()
    }
  }

  /// Every regular file under a region, with what trimming needs to order them.
  ///
  /// No `.skipsHiddenFiles`: `sanitize` permits a leading `.`, and such a name would
  /// then be uncounted, unevictable and reported absent by `mightHold`. The Dart
  /// integrity pass lists the same directories without skipping anything.
  private static func walk(_ directory: URL) -> [(String, UInt64, Date)] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: keys, options: [])
    else { return [] }

    var found: [(String, UInt64, Date)] = []
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
      found.append(
        (url.lastPathComponent, UInt64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
    }
    return found
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
  /// Call it from [io].
  static func data(name: String) -> Data? {
    if let file = pinnedPath(name), let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
      return data
    }
    if let file = cachePath(name), let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
      return data
    }
    return nil
  }

  // ---------------------------------------------------------------------------
  // Writing
  // ---------------------------------------------------------------------------

  /// Keeps bytes that were just fetched for the screen, in the opportunistic
  /// region only: deciding that a photo belongs in the mirror is the Dart side's
  /// job, and it claims these by renaming rather than downloading again.
  static func store(_ data: Data, name: String) {
    lock.lock()
    let keeping = cacheBudget > 0
    lock.unlock()
    guard keeping else { return }
    guard let target = cachePath(name), let pinned = pinnedPath(name) else { return }

    io.async(flags: .barrier) {
      guard !FileManager.default.fileExists(atPath: pinned.path) else { return }

      try? FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

      // What this write replaces, if anything. Two fetches for one tile can both
      // land, the second overwriting rather than adding, and counting both would
      // trim a region that was never over budget.
      let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
      let replaced = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

      // `.atomic` writes aside and renames into place: a half-written blob that
      // a later read memory-maps decodes as a corrupt image.
      guard (try? data.write(to: target, options: .atomic)) != nil else { return }

      lock.lock()
      present.insert(fnv1a64(name))
      cacheBytes = cacheBytes - min(cacheBytes, replaced) + UInt64(data.count)
      lock.unlock()

      trimCacheIfNeeded()
    }
  }

  /// Records a name Dart has just written into `pinned/`, so the next lookup for
  /// it does not have to discover it by missing first.
  static func noteStored(_ names: [String]) {
    lock.lock()
    for name in names {
      present.insert(fnv1a64(name))
    }
    lock.unlock()
  }

  /// Accounts for bytes Dart moved out of `cache/` into `pinned/`.
  ///
  /// A rename it performs itself is invisible here, so without this the region
  /// keeps counting bytes it no longer holds. The next trim recomputes from a
  /// walk, but a number that is only right after a trim is not worth showing.
  static func notePromoted(bytes: Int64) {
    guard bytes > 0 else { return }
    lock.lock()
    let amount = UInt64(bytes)
    cacheBytes = cacheBytes > amount ? cacheBytes - amount : 0
    lock.unlock()
  }

  /// Forgets names Dart has just deleted.
  ///
  /// The index only gates whether the filesystem is consulted, so a stale name
  /// costs one failed `open`. Dropping all of it is the honest answer to a bulk
  /// delete, since rebuilding is one walk.
  static func forgetAll() {
    lock.lock()
    present.removeAll()
    indexed = false
    cacheBytes = 0
    lock.unlock()
    prepare()
  }

  // ---------------------------------------------------------------------------
  // Trimming
  // ---------------------------------------------------------------------------

  /// Total bytes held in the opportunistic region.
  static func cacheSize() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return Int64(cacheBytes)
  }

  /// Empties the opportunistic region. `pinned/` is untouched: it is the library,
  /// not a cache, and has its own control.
  ///
  /// On [io] as a barrier, like every other write: off it, this removed the
  /// directory from under an in-flight `store()` and raced the trim's own recount.
  /// [done] runs after it, so a caller reporting what it freed does not answer
  /// before the bytes are gone.
  static func clearCache(done: (() -> Void)? = nil) {
    guard let cacheRoot else {
      done?()
      return
    }
    io.async(flags: .barrier) {
      try? FileManager.default.removeItem(at: cacheRoot)
      try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
      forgetAll()
      done?()
    }
  }

  private static func trimCacheIfNeeded() {
    lock.lock()
    let over = cacheBytes > cacheBudget && !trimming
    if over {
      trimming = true
    }
    lock.unlock()
    guard over else { return }
    guard let cacheRoot else {
      lock.lock()
      trimming = false
      lock.unlock()
      return
    }

    maintenance.async {
      // Oldest written first, not least recently read: access order would mean
      // a write on every cache hit, and this only has to be bounded.
      var files = walk(cacheRoot).sorted { $0.2 < $1.2 }
      var remaining = files.reduce(UInt64(0)) { $0 + $1.1 }
      let target = cacheBudget * 4 / 5

      var dropped: [UInt64] = []
      while remaining > target, !files.isEmpty {
        let (name, size, _) = files.removeFirst()
        guard let path = cachePath(name) else { continue }
        // Only bytes actually given back are counted: deducting on a failed
        // delete would let the loop conclude it is under budget with the files
        // still there.
        guard (try? FileManager.default.removeItem(at: path)) != nil else { continue }
        // The index covers both regions, so a pinned copy may still earn this
        // name — the reconciler writes there directly, without passing through
        // `store()` and its existence check. Dropping it would tell `mightHold`
        // that a mirrored photo is absent and send the image path to the network
        // for a file on disk, invisible until the user is offline.
        if let pinned = pinnedPath(name), !FileManager.default.fileExists(atPath: pinned.path) {
          dropped.append(fnv1a64(name))
        }
        remaining -= min(remaining, size)
      }

      lock.lock()
      present.subtract(dropped)
      cacheBytes = remaining
      trimming = false
      lock.unlock()
    }
  }
}
