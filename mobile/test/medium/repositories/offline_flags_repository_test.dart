/// immich-sync fork — which band a held file falls into (FORK.md §3.2, §3.6).
///
/// This is the predicate that decides what a removal is allowed to take, and it is SQL with no Dart twin on purpose:
/// one expression is what keeps the figure a screen quotes and the files a deletion takes the same set. So it is tested
/// against a real database rather than re-implemented here.
///
/// The case worth guarding is the one the rung alone gets wrong: an item whose original the camera roll holds is never
/// fetched in full by the mirror, so any full-size copy it does hold arrived by hand and is a spare — at every rung,
/// "keep full photos" included.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

void main() {
  late Directory dir;
  late OfflineFlagsRepository sut;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mirrich_flags');
    sut = await OfflineFlagsRepository.openAt('${dir.path}/offline.sqlite');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  const photo = 'photo-1';
  const video = 'video-1';

  Future<void> want(
    String id, {
    required OfflineQuality quality,
    bool isImage = true,
    bool hasMotion = false,
    bool onDemand = false,
  }) => sut.set([
    OfflineFlagRow(
      id: id,
      quality: quality,
      isImage: isImage,
      hasMotion: hasMotion,
      createdAt: DateTime.utc(2026, 8, 20),
      touchedAt: DateTime.utc(2026, 8, 21),
      onDemand: onDemand,
    ),
  ]);

  Future<void> hold(String id, OfflineVariant variant, int size) => sut.markHeld([
    OfflineHeldRow(name: '$id-${variant.name}', assetId: id, variant: variant, token: 1, size: size),
  ]);

  Future<void> holdWholePhoto(String id) async {
    await hold(id, OfflineVariant.thumbnail, 10);
    await hold(id, OfflineVariant.preview, 90);
    await hold(id, OfflineVariant.original, 900);
  }

  group('a full-size copy of a photo the camera roll holds', () {
    setUp(() async {
      await want(photo, quality: OfflineQuality.fullWithVideos);
      await holdWholePhoto(photo);
    });

    test('is library while nothing says the phone has the original', () async {
      final storage = await sut.storage();

      expect(storage.keptOriginalBytes, 900);
      expect(storage.spareOriginalBytes, 0);
    });

    test('becomes a spare once it does, at the top rung', () async {
      await sut.setLocalCopy({photo: true});
      final storage = await sut.storage();

      // The mirror never fetches this file (§3.2), so no selection can be said to maintain it, whatever the rung says.
      expect(storage.spareOriginalBytes, 900);
      expect(storage.keptOriginalBytes, 0);
    });

    test('and its previews stay library, or a removal would strand the item off the grid', () async {
      await sut.setLocalCopy({photo: true});
      final storage = await sut.storage();

      expect(storage.libraryPreviewBytes, 100);
      expect(storage.sparePreviewBytes, 0);
    });

    test('so a removal of every spare takes the original and leaves the previews', () async {
      await sut.setLocalCopy({photo: true});

      final plan = await sut.reclaimPlan();
      expect(plan.bytes, 900);
      expect(plan.files, 1);
      expect(plan.losingOriginals, 1);
      expect(plan.losingPreviews, 0);
    });

    test('goes back to library when the camera-roll copy does not survive Free Up Space', () async {
      await sut.setLocalCopy({photo: true});
      await sut.setLocalCopy({photo: false});
      final storage = await sut.storage();

      expect(storage.keptOriginalBytes, 900);
      expect(storage.spareOriginalBytes, 0);
    });

    test('survives a re-derivation, which knows nothing about the camera roll', () async {
      await sut.setLocalCopy({photo: true});
      // What applying a selection does: the row is rewritten, and an INSERT OR REPLACE here would silently reset the
      // flag and file the copy as library again.
      await want(photo, quality: OfflineQuality.fullWithVideos);

      expect((await sut.storage()).spareOriginalBytes, 900);
    });
  });

  test("a video's playable file follows the same rule", () async {
    await want(video, quality: OfflineQuality.fullWithVideos, isImage: false);
    await hold(video, OfflineVariant.thumbnail, 10);
    await hold(video, OfflineVariant.preview, 90);
    await hold(video, OfflineVariant.video, 5000);

    expect((await sut.storage()).keptVideoBytes, 5000);

    await sut.setLocalCopy({video: true});
    expect((await sut.storage()).spareVideoBytes, 5000);
  });

  test("a Live Photo's motion part follows it too, being a file of the photo", () async {
    await want(photo, quality: OfflineQuality.fullWithVideos, hasMotion: true);
    await hold(photo, OfflineVariant.video, 4000);

    expect((await sut.storage()).keptVideoBytes, 4000);

    await sut.setLocalCopy({photo: true});
    expect((await sut.storage()).spareVideoBytes, 4000);
  });

  test('the paged row reports what it believes, so a pass can correct it', () async {
    await want(photo, quality: OfflineQuality.full);
    expect((await sut.page(limit: 10)).single.localCopy, isFalse);

    await sut.setLocalCopy({photo: true});
    expect((await sut.page(limit: 10)).single.localCopy, isTrue);
  });

  test('a hand-fetched row is a spare throughout, local copy or not', () async {
    await want(photo, quality: OfflineQuality.fullWithVideos, onDemand: true);
    await holdWholePhoto(photo);

    final storage = await sut.storage();
    expect(storage.spareOriginalBytes, 900);
    expect(storage.sparePreviewBytes, 100);
  });
}
