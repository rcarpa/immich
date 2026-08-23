package app.alextran.immich.images

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * immich-sync fork: the blob name, pinned to the same literals as the Dart and Swift halves.
 *
 * Three languages derive this name and all three must agree byte for byte: Dart names a blob when
 * it downloads it, and Swift and Kotlin name it when the image path looks for it. A divergence is
 * silent in the worst way — every image simply falls through to the network, the mirror appears to
 * do nothing, and nothing anywhere says why. So these are the *same fixtures* as
 * `test/utils/offline_paths_test.dart`, with the same expected strings written out rather than
 * computed, and when one of them has to change every side changes in the same commit.
 */
class OfflineStoreNamingTest {
  // As built by `getThumbnailUrlForRemoteId`, with the thumbhash percent-encoded the way
  // `Uri.encodeComponent` leaves it.
  private val preview =
    "https://photos.example.com/api/assets/abc123/thumbnail?size=preview&edited=true&c=hash%2Fone"

  @Test
  fun `derives a readable name from the path, the size and a query token`() {
    assertEquals("assets_abc123_thumbnail_preview_eb9fc1d4", OfflineStore.fileName(preview))
  }

  @Test
  fun `ignores scheme and host, so endpoint switching resolves to one file`() {
    // Upstream moves between the LAN and external addresses on its own. A name that carried the
    // host would store the library once per endpoint.
    assertEquals(
      OfflineStore.fileName(preview),
      OfflineStore.fileName(
        "http://192.168.1.9:2283/api/assets/abc123/thumbnail?size=preview&edited=true&c=hash%2Fone"
      ),
    )
  }

  @Test
  fun `ignores query order`() {
    assertEquals(
      OfflineStore.fileName(preview),
      OfflineStore.fileName(
        "https://photos.example.com/api/assets/abc123/thumbnail?c=hash%2Fone&edited=true&size=preview"
      ),
    )
  }

  @Test
  fun `takes the last value of a repeated key, as every side does`() {
    assertEquals(
      OfflineStore.fileName(preview),
      OfflineStore.fileName(
        "https://photos.example.com/api/assets/abc123/thumbnail?size=preview&edited=false&edited=true&c=hash%2Fone"
      ),
    )
  }

  @Test
  fun `changes when the asset is edited, so stale bytes are never served`() {
    assertEquals(
      "assets_abc123_thumbnail_preview_6c6c3f2a",
      OfflineStore.fileName(
        "https://photos.example.com/api/assets/abc123/thumbnail?size=preview&edited=true&c=hash%2Ftwo"
      ),
    )
  }

  @Test
  fun `separates the sizes of one asset`() {
    assertEquals(
      "assets_abc123_thumbnail_thumbnail_eb9fc1d4",
      OfflineStore.fileName(
        "https://photos.example.com/api/assets/abc123/thumbnail?size=thumbnail&edited=true&c=hash%2Fone"
      ),
    )
  }

  @Test
  fun `suffixes playable URLs with mp4, which the player needs`() {
    assertEquals(
      "assets_abc123_video_playback_811c9dc5.mp4",
      OfflineStore.fileName("https://photos.example.com/api/assets/abc123/video/playback"),
    )
    assertEquals(
      "assets_abc123_original_f83372e3.mp4",
      OfflineStore.fileName("https://photos.example.com/api/assets/abc123/original?edited=true"),
    )
  }

  @Test
  fun `names an empty query, which several stored URLs have`() {
    // Every side folds "no query" to the hash of the empty string, not to no segment at all.
    assertEquals(
      "assets_abc123_thumbnail_811c9dc5",
      OfflineStore.fileName("https://photos.example.com/api/assets/abc123/thumbnail"),
    )
  }

  @Test
  fun `reads a valueless query key as empty`() {
    // Dart maps a bare key to "" and taking it as "absent" would drop the size segment on one
    // side. Hence the double underscore.
    assertEquals(
      "assets_abc123_thumbnail__811c9dc5",
      OfflineStore.fileName("https://photos.example.com/api/assets/abc123/thumbnail?size"),
    )
  }

  @Test
  fun `stays one path component`() {
    // Names are joined onto a bucket directory, so a surviving separator writes outside the store.
    for (url in listOf(
      "https://photos.example.com/api/assets/../../etc/passwd/thumbnail?size=preview",
      "https://photos.example.com/api/assets/a%2Fb/thumbnail?size=pre%2Fview",
    )) {
      val name = OfflineStore.fileName(url)!!
      assertTrue(name.isNotEmpty())
      assertTrue("'$name' must not contain a separator", !name.contains('/'))
    }
  }

  @Test
  fun `decodes a plus in a query value as a space`() {
    // The one place Kotlin's obvious spelling diverges from Dart's: `Uri.queryParameters` decodes
    // `+` to a space, and a single `URLDecoder.decode` for both halves would be wrong for one of
    // them. It shows up here because query values are hashed *before* sanitising, so the decoded
    // character survives into the token.
    assertEquals(
      OfflineStore.fileName("https://e.com/api/assets/x/thumbnail?c=a%20b"),
      OfflineStore.fileName("https://e.com/api/assets/x/thumbnail?c=a+b"),
    )
  }

  @Test
  fun `decodes percent escapes in a path`() {
    // And the other half: `Uri.pathSegments` percent-decodes, so an escaped safe character has to
    // come back as itself rather than as the escape.
    //
    // Note what cannot be tested here. A `+` in a path stays a `+` in Dart and a space would not,
    // but sanitising maps both to `-`, so no name can tell them apart — which is why the assertion
    // this replaced was checking something that is not observable.
    assertEquals(
      OfflineStore.fileName("https://e.com/api/assets/ABC/thumbnail"),
      OfflineStore.fileName("https://e.com/api/assets/%41BC/thumbnail"),
    )
  }

  @Test
  fun `orders the query by UTF-8 bytes, not by string comparison`() {
    // Kotlin's String.compareTo orders by UTF-16 code unit and Dart's by the same, but Swift's
    // orders by Unicode canonical equivalence — so all three agree only if the ordering is done on
    // bytes. Two keys that straddle the surrogate range are what tell them apart.
    val one = OfflineStore.fileName("https://e.com/api/assets/x/thumbnail?ａ=1&😀=2")
    val other = OfflineStore.fileName("https://e.com/api/assets/x/thumbnail?😀=2&ａ=1")
    assertEquals(one, other)
  }
}
