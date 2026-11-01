import Foundation

enum NativeCore {
  private static let library = dlopen("@rpath/native_core_ffi.framework/native_core_ffi", RTLD_NOW)

  private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let library, let symbol = dlsym(library, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
  }

  private static let coreThumbhash = symbol("native_core_thumbhash", as: NativeCoreThumbhashFn.self)
  private static let coreDecodeImage = symbol("native_core_decode_image", as: NativeCoreDecodeImageFn.self)
  private static let coreCancel = symbol("native_core_cancel", as: NativeCoreCancelFn.self)

  static func thumbhash(_ hash: Data) -> (width: Int, height: Int, pointer: UnsafeMutableRawPointer)? {
    guard let coreThumbhash else { return nil }
    var width: Int32 = 0
    var height: Int32 = 0
    return hash.withUnsafeBytes { bytes in
      guard let pointer = coreThumbhash(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &width, &height)
      else { return nil }
      return (Int(width), Int(height), UnsafeMutableRawPointer(pointer))
    }
  }

  static func decodeImage(_ data: Data, targetWidth: Int64?, targetHeight: Int64?, maxPixelSize: Int, cancelled: UnsafeMutablePointer<Bool>) -> (width: Int, height: Int, pointer: UnsafeMutableRawPointer)? {
    guard let coreDecodeImage else { return nil }
    var info = NativeCoreImageInfo()
    return data.withUnsafeBytes { bytes in
      guard let pointer = coreDecodeImage(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, false, UInt32(clamping: targetWidth ?? 0), UInt32(clamping: targetHeight ?? 0), UInt32(clamping: maxPixelSize), cancelled, &info)
      else { return nil }
      return (Int(info.width), Int(info.height), UnsafeMutableRawPointer(pointer))
    }
  }

  static func cancel(_ flag: UnsafeMutablePointer<Bool>) {
    coreCancel?(flag)
  }

  // immich-sync fork: the offline store's file naming (`offline_name.rs`), which Dart and Kotlin call too.
  private static let coreOfflineName = symbol("native_core_offline_name", as: NativeCoreOfflineNameFn.self)
  private static let coreOfflineBucket = symbol("native_core_offline_bucket", as: NativeCoreOfflineBucketFn.self)
  private static let coreFreeString = symbol("native_core_free_string", as: NativeCoreFreeStringFn.self)
  private static let coreOfflineNameHash = symbol("native_core_offline_name_hash", as: NativeCoreOfflineNameHashFn.self)

  /// Whether the core loaded with the offline naming; without it every lookup misses.
  static var hasOfflineNaming: Bool {
    coreOfflineName != nil && coreOfflineBucket != nil && coreFreeString != nil && coreOfflineNameHash != nil
  }

  /// The offline store's file name for a remote URL, or nil for one it never stores.
  static func offlineName(_ url: String) -> String? {
    guard let coreOfflineName, let coreFreeString, let name = url.withCString({ coreOfflineName($0) }) else {
      return nil
    }
    defer { coreFreeString(name) }
    return String(cString: name)
  }

  /// A 64-bit hash of a stored name, the same bits Dart and Kotlin index files by; nil without the core.
  static func offlineNameHash(_ name: String) -> UInt64? {
    guard let coreOfflineNameHash else { return nil }
    return name.withCString { coreOfflineNameHash($0) }
  }

  /// The bucket directory, 0 to 255, a stored name goes in; nil without the core.
  static func offlineBucket(_ name: String) -> Int? {
    guard let coreOfflineBucket else { return nil }
    let bucket = name.withCString { coreOfflineBucket($0) }
    return bucket < 0 ? nil : Int(bucket)
  }
}
