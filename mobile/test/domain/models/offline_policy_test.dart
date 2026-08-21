/// immich-sync fork — the ladder, which decides how much of the library lands on
/// the phone.
///
/// Two things are pinned here. The rungs resolve to *files*, so a change to
/// `keepsOriginal` or `videoTier` that looks harmless is caught before it turns
/// "previews" into a video mirror. And the persisted names round-trip, since a
/// selection that decodes to something else re-derives the whole library at the
/// wrong quality without an error anywhere.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

void main() {
  group('OfflineQuality', () {
    test('only the top rung asks for a playable video', () {
      expect(OfflineQuality.none.videoTier, OfflineVideoTier.none);
      expect(OfflineQuality.preview.videoTier, OfflineVideoTier.none);
      expect(OfflineQuality.full.videoTier, OfflineVideoTier.none);
      expect(OfflineQuality.fullWithVideos.videoTier, OfflineVideoTier.playback);
    });

    test('full quality and above keep a photo original', () {
      expect(OfflineQuality.none.keepsOriginal, isFalse);
      expect(OfflineQuality.preview.keepsOriginal, isFalse);
      expect(OfflineQuality.full.keepsOriginal, isTrue);
      expect(OfflineQuality.fullWithVideos.keepsOriginal, isTrue);
    });

    test('combining selections takes the most generous rung', () {
      expect(OfflineQuality.preview.atLeast(OfflineQuality.fullWithVideos), OfflineQuality.fullWithVideos);
      expect(OfflineQuality.fullWithVideos.atLeast(OfflineQuality.preview), OfflineQuality.fullWithVideos);
      expect(OfflineQuality.full.atLeast(OfflineQuality.preview), OfflineQuality.full);
    });

    test('codes survive a round trip', () {
      for (final quality in OfflineQuality.values) {
        expect(OfflineQuality.fromCode(quality.code), quality);
      }
    });
  });

  group('OfflinePolicy', () {
    const album = 'album-1';

    test('an excluded album wins over the most generous selection', () {
      const policy = OfflinePolicy(
        library: OfflineQuality.fullWithVideos,
        albums: {album: OfflineQuality.full},
        excluded: {album},
      );
      expect(policy.resolve([album]), isNull);
    });

    test('an album may ask for more than the library', () {
      const policy = OfflinePolicy(library: OfflineQuality.preview, albums: {album: OfflineQuality.fullWithVideos});
      expect(policy.resolve([album]), OfflineQuality.fullWithVideos);
      expect(policy.resolve(const []), OfflineQuality.preview);
    });

    test('encoding round-trips every rung', () {
      const policy = OfflinePolicy(
        library: OfflineQuality.fullWithVideos,
        albums: {'a': OfflineQuality.preview, 'b': OfflineQuality.full},
        excluded: {'c'},
      );
      expect(OfflinePolicy.decode(policy.encode()), policy);
    });

    test('a malformed value selects nothing rather than throwing', () {
      expect(OfflinePolicy.decode('not json'), OfflinePolicy.empty);
    });
  });

  group('OfflineVariant.fetchOrder', () {
    test('runs cheapest and most useful first', () {
      final variants = [OfflineVariant.video, OfflineVariant.preview, OfflineVariant.original, OfflineVariant.thumbnail]
        ..sort((a, b) => a.fetchOrder.compareTo(b.fetchOrder));

      expect(variants, [
        OfflineVariant.thumbnail,
        OfflineVariant.preview,
        OfflineVariant.original,
        OfflineVariant.video,
      ]);
    });
  });
}
