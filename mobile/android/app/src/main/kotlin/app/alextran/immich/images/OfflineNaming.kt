package app.alextran.immich.images

/**
 * immich-sync fork: the offline store's file naming, from the native core (`offline_name.rs`), which Dart and Swift
 * call too, so every side names a file the same way.
 */
object OfflineNaming {
  init {
    System.loadLibrary("native_core_ffi")
  }

  /** The file name for a remote URL, or null for a URL with a malformed escape. */
  @JvmStatic
  external fun fileName(url: String): String?

  /** The bucket directory, 0 to 255, a stored name goes in. */
  @JvmStatic
  external fun bucket(name: String): Int

  /** A 64-bit hash of a stored name, the same bits Dart and Swift index files by. */
  @JvmStatic
  external fun nameHash(name: String): Long
}
