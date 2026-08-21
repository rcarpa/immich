/// immich-sync fork — the one invariant nothing else can catch.
///
/// `offline_paths.dart` and `ios/Runner/Images/OfflineStore.swift` derive a
/// filename from the same URL, independently, in two languages. If they ever
/// disagree, every read misses silently: no error, no crash, just a library that
/// re-downloads itself on every pass and never opens off-grid.
///
/// So the expected names below are written out in full rather than computed, and
/// they are the vectors the Swift side has to reproduce. Changing one means
/// changing `OfflineStore.fileName` in the same commit — and a stored library
/// re-derives under the new names, which is a full re-download for every user.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

void main() {
  // As built by `getThumbnailUrlForRemoteId`, with the thumbhash percent-encoded
  // the way `Uri.encodeComponent` leaves it.
  const preview = 'https://photos.example.com/api/assets/abc123/thumbnail?size=preview&edited=true&c=hash%2Fone';

  group('offlineBlobName', () {
    test('derives a readable name from the path, the size and a query token', () {
      expect(offlineBlobName(preview), 'assets_abc123_thumbnail_preview_eb9fc1d4');
    });

    test('ignores scheme and host, so endpoint switching resolves to one file', () {
      // Upstream moves between the LAN and external addresses on its own. A name
      // that carried the host would store the library once per endpoint.
      expect(
        offlineBlobName('http://192.168.1.9:2283/api/assets/abc123/thumbnail?size=preview&edited=true&c=hash%2Fone'),
        offlineBlobName(preview),
      );
    });

    test('ignores query order', () {
      expect(
        offlineBlobName('https://photos.example.com/api/assets/abc123/thumbnail?c=hash%2Fone&edited=true&size=preview'),
        offlineBlobName(preview),
      );
    });

    test('takes the last value of a repeated key, as both sides do', () {
      expect(
        offlineBlobName(
          'https://photos.example.com/api/assets/abc123/thumbnail?size=preview&edited=false&edited=true&c=hash%2Fone',
        ),
        offlineBlobName(preview),
      );
    });

    test('changes when the asset is edited, so stale bytes are never served', () {
      expect(
        offlineBlobName('https://photos.example.com/api/assets/abc123/thumbnail?size=preview&edited=true&c=hash%2Ftwo'),
        'assets_abc123_thumbnail_preview_6c6c3f2a',
      );
    });

    test('separates the sizes of one asset', () {
      expect(
        offlineBlobName(
          'https://photos.example.com/api/assets/abc123/thumbnail?size=thumbnail&edited=true&c=hash%2Fone',
        ),
        'assets_abc123_thumbnail_thumbnail_eb9fc1d4',
      );
    });

    test('suffixes playable URLs with .mp4, which AVFoundation needs', () {
      // An extensionless file opens as a black frame.
      expect(
        offlineBlobName('https://photos.example.com/api/assets/abc123/video/playback'),
        'assets_abc123_video_playback_811c9dc5.mp4',
      );
      expect(
        offlineBlobName('https://photos.example.com/api/assets/abc123/original?edited=true'),
        'assets_abc123_original_f83372e3.mp4',
      );
    });

    test('names an empty query, which several stored URLs have', () {
      // Both sides fold "no query" to the hash of the empty string, not to no
      // segment at all.
      expect(
        offlineBlobName('https://photos.example.com/api/assets/abc123/thumbnail'),
        'assets_abc123_thumbnail_811c9dc5',
      );
    });

    test('reads a valueless query key as empty, as Dart and Swift both must', () {
      // Dart maps a bare key to `''` and Swift's `queryItems` to nil; taking that as
      // "absent" would drop the size segment on one side. Hence the double
      // underscore.
      expect(
        offlineBlobName('https://photos.example.com/api/assets/abc123/thumbnail?size'),
        'assets_abc123_thumbnail__811c9dc5',
      );
    });

    group('stays one path component', () {
      // Names are joined onto a bucket directory, so a surviving separator writes
      // outside the store. Containment, not parity: an encoded separator lands
      // inside a segment in Dart and splits one in Swift, Immich emits neither, and
      // both sides join with `_` so neither can emit a `/`.
      const hostile = [
        'https://photos.example.com/api/assets/%2E%2E%2F%2E%2E%2Fetc%2Fpasswd/thumbnail?size=preview',
        'https://photos.example.com/api/assets/%2E%2E/original?edited=true',
        r'https://photos.example.com/api/assets/a%5Cb/thumbnail?size=preview',
        'https://photos.example.com/api/assets/abc123/thumbnail?size=%2E%2E%2F%2E%2E',
        'https://photos.example.com/api/assets/f%C3%B6%C3%B6/thumbnail?size=preview',
      ];

      for (final url in hostile) {
        test(url, () {
          final name = offlineBlobName(url);
          expect(name, isNotEmpty);
          expect(name.contains('/'), isFalse);
          expect(name.contains(r'\'), isFalse);
          expect(name, isNot('.'));
          expect(name, isNot('..'));
        });
      }
    });
  });

  group('OfflineFile.token', () {
    // `/original?edited=true` resolves to `editedPath ?? originalPath`, so its bytes
    // change on an edit and the name has to move with them.
    const plain = 'https://photos.example.com/api/assets/abc123/original?edited=true';
    const editedOnce = 'https://photos.example.com/api/assets/abc123/original?edited=true&c=hash%2Fone';
    const editedTwice = 'https://photos.example.com/api/assets/abc123/original?edited=true&c=hash%2Ftwo';

    test('moves when an edited original is edited again', () {
      final one = OfflineFile(editedOnce, OfflineVariant.original);
      final two = OfflineFile(editedTwice, OfflineVariant.original);
      expect(one.token, isNot(two.token));
      expect(one.name, isNot(two.name));
    });

    test('separates an edited original from the unedited one', () {
      expect(
        OfflineFile(editedOnce, OfflineVariant.original).name,
        isNot(OfflineFile(plain, OfflineVariant.original).name),
      );
    });

    test('leaves an unedited original where it already is', () {
      // Busting it would rename every original on every device for identical bytes.
      expect(OfflineFile(plain, OfflineVariant.original).name, 'assets_abc123_original_f83372e3.mp4');
      expect(OfflineFile(plain, OfflineVariant.original).token, 0xf83372e3);
    });

    test('is the query token for a thumbnail, and the name for a video', () {
      expect(OfflineFile(preview, OfflineVariant.preview).token, 0xeb9fc1d4);
      // A video has no buster, so its generation is the name `loadOriginalVideo`
      // picked.
      expect(
        OfflineFile('https://photos.example.com/api/assets/abc123/video/playback', OfflineVariant.video).token,
        isNot(OfflineFile('https://photos.example.com/api/assets/abc123/original', OfflineVariant.video).token),
      );
    });
  });

  group('offlineBlobBucket', () {
    test('spreads an asset over buckets rather than one directory', () {
      // Every name starts `assets_`, so the first characters cannot bucket them.
      expect(offlineBlobBucket('assets_abc123_thumbnail_preview_eb9fc1d4'), '4e');
      expect(offlineBlobBucket('assets_abc123_video_playback_811c9dc5.mp4'), 'c3');
    });

    test('is always two hex digits', () {
      for (var i = 0; i < 512; i++) {
        expect(offlineBlobBucket('assets_$i-thumbnail'), matches(RegExp(r'^[0-9a-f]{2}$')));
      }
    });
  });

  group('offlineNameHash', () {
    test('is the 64-bit FNV-1a of the name', () {
      // The integrity pass ships the wanted set as these integers, so a change
      // here makes the pass keep files it should sweep — never the reverse, but
      // the store stops shrinking.
      expect(offlineNameHash(''), -3750763034362895579);
      expect(offlineNameHash('assets_abc123_thumbnail_preview_eb9fc1d4'), isNot(offlineNameHash('assets_abc123')));
    });
  });
}
