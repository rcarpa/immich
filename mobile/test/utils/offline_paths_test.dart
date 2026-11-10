/// immich-sync fork: the naming lives in the native core (`offline_name.rs`, tested against the same fixture in Rust),
/// which Swift and Kotlin call too. These check it through Dart's binding.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

void main() {
  /// The names stored files already have.
  final lines = File('../native/crates/native_core/tests/fixtures/offline_names.tsv').readAsLinesSync();
  final fixture = {
    for (final line in lines.where((line) => line.isNotEmpty))
      line.split('\t')[0]: line.split('\t')[1],
  };

  group('the shared fixture', () {
    test('is named as written', () {
      expect(fixture, isNotEmpty);
      for (final MapEntry(key: url, value: name) in fixture.entries) {
        expect(offlineBlobName(url), name, reason: url);
      }
    });
  });

  // As built by `getThumbnailUrlForRemoteId`, with the thumbhash percent-encoded like `Uri.encodeComponent`.
  const preview = 'https://photos.example.com/api/assets/abc123/thumbnail?size=preview&edited=true&c=hash%2Fone';

  group('offlineBlobName', () {
    test('derives a readable name from the path, the size and a query token', () {
      expect(offlineBlobName(preview), 'assets_abc123_thumbnail_preview_eb9fc1d4');
    });

    test('ignores scheme and host, so endpoint switching resolves to one file', () {
      // The app switches between LAN and external addresses, so the host must not be in the name.
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
      // "No query" hashes the empty string.
      expect(
        offlineBlobName('https://photos.example.com/api/assets/abc123/thumbnail'),
        'assets_abc123_thumbnail_811c9dc5',
      );
    });

    test('reads a valueless query key as empty, as Dart and Swift both must', () {
      // A bare key is `''` here and nil in Swift; both keep the size segment, hence the double underscore.
      expect(
        offlineBlobName('https://photos.example.com/api/assets/abc123/thumbnail?size'),
        'assets_abc123_thumbnail__811c9dc5',
      );
    });

    group('stays one path component', () {
      // A surviving separator would write outside the store.
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

  group('offlineUnprefixedName', () {
    test('drops the server path before the API root', () {
      expect(
        offlineUnprefixedName('immich_api_assets_x_thumbnail_preview_811c9dc5'),
        'assets_x_thumbnail_preview_811c9dc5',
      );
      expect(offlineUnprefixedName('a_api_b_api_people_p1_thumbnail_ca08d264'), 'people_p1_thumbnail_ca08d264');
    });

    test('leaves names that never had one', () {
      expect(offlineUnprefixedName('assets_x_thumbnail_preview_811c9dc5'), isNull);
      expect(offlineUnprefixedName('people_p1_thumbnail_ca08d264'), isNull);
    });

    test('gives what the naming now gives for the same URL', () {
      expect(
        offlineUnprefixedName('immich_api_assets_x_thumbnail_preview_811c9dc5'),
        offlineBlobName('https://e.com/immich/api/assets/x/thumbnail?size=preview'),
      );
    });
  });

  group('OfflineFile.token', () {
    // `/original?edited=true` changes bytes on an edit, so the name must change too.
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
      // A video has no cache buster; its version is the URL `loadOriginalVideo` picked.
      expect(
        OfflineFile('https://photos.example.com/api/assets/abc123/video/playback', OfflineVariant.video).token,
        isNot(OfflineFile('https://photos.example.com/api/assets/abc123/original', OfflineVariant.video).token),
      );
      // The value held rows already carry, from when Dart hashed the name itself.
      expect(
        OfflineFile('https://photos.example.com/api/assets/abc123/video/playback', OfflineVariant.video).token,
        0x14ea45c3,
      );
    });
  });

  group('offlineAssetIdOf', () {
    const id = '0b8f4a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b';

    test('reads the asset back out of every name the mirror gives its files', () {
      for (final url in [
        'https://example.com/api/assets/$id/thumbnail?size=thumbnail&edited=true&c=abc',
        'https://example.com/api/assets/$id/thumbnail?size=preview&edited=true&c=abc',
        'https://example.com/api/assets/$id/original?edited=true',
        'https://example.com/api/assets/$id/video/playback',
      ]) {
        expect(offlineAssetIdOf(offlineBlobName(url)), id, reason: url);
      }
    });

    test("answers null for a file that is not an asset's", () {
      expect(offlineAssetIdOf(offlineBlobName('https://example.com/api/people/$id/thumbnail?c=1')), isNull);
    });
  });

  group('offlineVariantOfName', () {
    const id = '0b8f4a2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b';
    String name(String path) => offlineBlobName('https://example.com/api/$path');

    test('files each kind of asset file under the row it looks like', () {
      expect(offlineVariantOfName(name('assets/$id/thumbnail?size=thumbnail&c=1')), OfflineVariant.thumbnail);
      expect(offlineVariantOfName(name('assets/$id/thumbnail?size=preview&c=1')), OfflineVariant.preview);
      expect(offlineVariantOfName(name('assets/$id/thumbnail?size=fullsize&c=1')), OfflineVariant.original);
      expect(offlineVariantOfName(name('assets/$id/original?edited=true')), OfflineVariant.original);
      expect(offlineVariantOfName(name('assets/$id/video/playback')), OfflineVariant.video);
    });

    test('files what is no asset at all — a face — with thumbnails', () {
      expect(offlineVariantOfName(name('people/$id/thumbnail?c=1')), OfflineVariant.thumbnail);
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
      // The integrity pass ships the wanted set as these integers.
      expect(offlineNameHash(''), -3750763034362895579);
      expect(offlineNameHash('assets_abc123_thumbnail_preview_eb9fc1d4'), isNot(offlineNameHash('assets_abc123')));
    });
  });
}
