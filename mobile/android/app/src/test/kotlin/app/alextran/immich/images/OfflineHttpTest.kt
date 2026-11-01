package app.alextran.immich.images

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/** immich-sync fork: what resuming a large download relies on. A wrong answer here appends to the wrong file. */
class OfflineHttpTest {
  @Test
  fun `parses a content range with and without a known total`() {
    assertEquals(OfflineHttp.ContentRange(100, 199, 1000), OfflineHttp.parseContentRange("bytes 100-199/1000"))
    assertEquals(OfflineHttp.ContentRange(0, 9, null), OfflineHttp.parseContentRange("bytes 0-9/*"))
    assertEquals(OfflineHttp.ContentRange(5, 5, 6), OfflineHttp.parseContentRange("  Bytes 5-5/6 "))
  }

  @Test
  fun `rejects ranges that do not describe bytes received`() {
    for (header in listOf(null, "", "bytes */1000", "bytes 200-100/1000", "bytes 0-1000/1000", "items 0-1/2", "bytes 0-1")) {
      assertNull(header, OfflineHttp.parseContentRange(header))
    }
  }

  @Test
  fun `prefers a strong etag, then the modification date, then a weak etag`() {
    assertEquals("\"abc\"", OfflineHttp.validator("\"abc\"", "Sat, 31 Oct 2026 10:00:00 GMT"))
    assertEquals("Sat, 31 Oct 2026 10:00:00 GMT", OfflineHttp.validator("W/\"abc\"", "Sat, 31 Oct 2026 10:00:00 GMT"))
    assertEquals("W/\"abc\"", OfflineHttp.validator("W/\"abc\"", null))
    assertNull(OfflineHttp.validator(null, " "))
  }

  @Test
  fun `resumes only a non-empty partial file with its validator`() {
    val directory = Files.createTempDirectory("offline-http").toFile()
    try {
      val partial = directory.resolve("a.part")
      val meta = directory.resolve("a.meta")

      partial.writeBytes(ByteArray(42))
      OfflineHttp.writeResume(meta, "\"tag\"")
      assertEquals(OfflineHttp.Resume(42, "\"tag\""), OfflineHttp.readResume(partial, meta))

      // No validator: the bytes cannot be trusted to be a prefix of the file now on the server.
      meta.delete()
      assertNull(OfflineHttp.readResume(partial, meta))
      assertFalse(partial.exists())

      // Empty: nothing to resume.
      partial.writeBytes(ByteArray(0))
      OfflineHttp.writeResume(meta, "\"tag\"")
      assertNull(OfflineHttp.readResume(partial, meta))
      assertFalse(meta.exists())
    } finally {
      directory.deleteRecursively()
    }
  }

  @Test
  fun `keeps images and unnamed types, never a page answered with 200`() {
    for (type in listOf(null, "", "image/jpeg", "Image/WebP; charset=binary", "application/octet-stream")) {
      assertTrue(type.toString(), OfflineStore.keepsType(type))
    }
    for (type in listOf("text/html", "text/html; charset=utf-8", "application/json", "text/plain")) {
      assertFalse(type, OfflineStore.keepsType(type))
      assertFalse(type, OfflineStore.keepsType(type, video = true))
    }
    // Only the queue downloads videos.
    assertFalse(OfflineStore.keepsType("video/mp4"))
    assertTrue(OfflineStore.keepsType("video/mp4", video = true))
  }
}
