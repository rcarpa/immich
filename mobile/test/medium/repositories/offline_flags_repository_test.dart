/// immich-sync fork: which band a held file falls into. The predicate is SQL with no Dart twin, so it is tested against
/// a real database. The key case: a full-size copy of an item the camera roll holds is always a spare, at every rung.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

import '../repository_context.dart';

/// More than any test store holds, so eviction offers every spare.
const _everything = 1 << 40;

void main() {
  late MediumRepositoryContext ctx;
  late OfflineFlagsRepository sut;

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = await ctx.offlineFlags();
  });

  tearDown(() async {
    await ctx.dispose();
  });

  late String ownerId;
  late String photo;
  late String video;

  /// The assets the rows below are about; the band predicate reads them from upstream's table.
  setUp(() async {
    ownerId = (await ctx.newUser()).id;
    final image = await ctx.newRemoteAsset(ownerId: ownerId, type: AssetType.image);
    photo = image.id;
    video = (await ctx.newRemoteAsset(ownerId: ownerId, type: AssetType.video)).id;
  });

  /// Puts a copy of an asset in the camera roll, matched by checksum as upstream's merged view matches it.
  Future<void> inCameraRoll([String? assetId]) async {
    final row = await (ctx.db.select(
      ctx.db.remoteAssetEntity,
    )..where((asset) => asset.id.equals(assetId ?? photo))).getSingle();
    await ctx.newLocalAsset(checksum: row.checksum);
  }

  /// And takes it away again, which is what upstream's Free Up Space does.
  Future<void> leftCameraRoll() async {
    await ctx.db.delete(ctx.db.localAssetEntity).go();
  }

  /// Makes [photo] a Live Photo, whose motion part is stored as a file of the photo itself.
  Future<void> withMotion() async {
    final motion = await ctx.newRemoteAsset(
      ownerId: ownerId,
      type: AssetType.video,
      visibility: AssetVisibility.hidden,
    );
    await (ctx.db.update(
      ctx.db.remoteAssetEntity,
    )..where((row) => row.id.equals(photo))).write(RemoteAssetEntityCompanion(livePhotoVideoId: Value(motion.id)));
  }

  Future<void> want(String id, {required OfflineQuality quality, bool onDemand = false}) => sut.set([
    OfflineFlagRow(
      id: id,
      quality: quality,
      createdAt: DateTime.utc(2026, 8, 20),
      touchedAt: DateTime.utc(2026, 8, 21),
      onDemand: onDemand,
    ),
  ]);

  Future<void> hold(String id, OfflineVariant variant, int size) =>
      sut.markHeld([OfflineHeldRow(name: '$id-${variant.name}', assetId: id, variant: variant, token: 1, size: size)]);

  Future<void> holdWholePhoto(String id) async {
    await hold(id, OfflineVariant.thumbnail, 10);
    await hold(id, OfflineVariant.preview, 90);
    await hold(id, OfflineVariant.original, 900);
  }

  test('a file-backed offline schema is switched to WAL, which an ATTACH does not inherit', () async {
    final dir = await Directory.systemTemp.createTemp('offline_wal');
    final file = MediumRepositoryContext();
    try {
      await file.db.customStatement("ATTACH DATABASE '${dir.path}/offline.sqlite' AS $kOfflineSchema");
      await OfflineFlagsRepository.forConnection(file.db);
      final row = await file.db.customSelect('PRAGMA $kOfflineSchema.journal_mode').getSingle();
      expect(row.data['journal_mode'], 'wal');
    } finally {
      await file.dispose();
      await dir.delete(recursive: true);
    }
  });

  group('a trashed item', () {
    setUp(() async {
      await sut.setUpstreamComplete();
      await sut.derive(const OfflinePolicy(library: OfflineQuality.full), DateTime.now());
      await holdWholePhoto(photo);
      await (ctx.db.update(
        ctx.db.remoteAssetEntity,
      )..where((row) => row.id.equals(photo))).write(RemoteAssetEntityCompanion(deletedAt: Value(DateTime.now())));
      await sut.derive(const OfflinePolicy(library: OfflineQuality.full), DateTime.now());
    });

    test('is selected by nothing, so its copies are spares', () async {
      expect((await sut.page(limit: 10)).map((want) => want.id), isNot(contains(photo)));
      expect((await sut.reclaimPlan()).bytes, 1000);
      expect((await sut.evictionCandidates(bytes: _everything)).map((row) => row.assetId).toSet(), {photo});
    });

    test('is selected again once restored', () async {
      await (ctx.db.update(
        ctx.db.remoteAssetEntity,
      )..where((row) => row.id.equals(photo))).write(const RemoteAssetEntityCompanion(deletedAt: Value(null)));
      await sut.derive(const OfflinePolicy(library: OfflineQuality.full), DateTime.now());

      expect((await sut.reclaimPlan()).bytes, 0);
    });
  });

  group('an item missing from upstream', () {
    setUp(() async {
      await want(photo, quality: OfflineQuality.full);
      await holdWholePhoto(photo);
      await (ctx.db.delete(ctx.db.remoteAssetEntity)..where((row) => row.id.equals(photo))).go();
    });

    test('is library while upstream may still be syncing it back', () async {
      final storage = await sut.storage();

      expect(storage.spareOriginalBytes + storage.sparePreviewBytes + storage.spareThumbnailBytes, 0);
      expect(await sut.evictionCandidates(bytes: _everything), isEmpty);
      expect((await sut.reclaimPlan()).files, 0);
      // Still counted in the other band, so "free up space" on library files can take it.
      final maintained = OfflineReclaim({
        for (final kind in OfflineReclaimKind.values) (OfflineReclaimBand.maintained, kind),
      });
      expect((await sut.reclaimPlan(what: maintained)).files, 3);
    });

    test('is a spare once upstream is complete', () async {
      await sut.setUpstreamComplete();

      expect((await sut.evictionCandidates(bytes: _everything)).map((row) => row.assetId).toSet(), {photo});
      expect((await sut.reclaimPlan()).bytes, 1000);
    });
  });

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
      await inCameraRoll();
      final storage = await sut.storage();

      // The mirror never fetches this file, so no selection can be said to maintain it, whatever the rung says.
      expect(storage.spareOriginalBytes, 900);
      expect(storage.keptOriginalBytes, 0);
    });

    test('and its previews stay library, or a removal would strand the item off the grid', () async {
      await inCameraRoll();
      final storage = await sut.storage();

      expect(storage.libraryPreviewBytes, 90);
      expect(storage.libraryThumbnailBytes, 10);
      expect(storage.sparePreviewBytes + storage.spareThumbnailBytes, 0);
    });

    test('so a removal of every spare takes the original and leaves the previews', () async {
      await inCameraRoll();

      final plan = await sut.reclaimPlan();
      expect(plan.bytes, 900);
      expect(plan.files, 1);
      expect(plan.losingOriginals, 1);
      expect(plan.losingPreviews, 0);
    });

    test('goes back to library when the camera-roll copy does not survive Free Up Space', () async {
      await inCameraRoll();
      await leftCameraRoll();
      final storage = await sut.storage();

      expect(storage.keptOriginalBytes, 900);
      expect(storage.spareOriginalBytes, 0);
    });

    test('survives a re-derivation, which knows nothing about the camera roll', () async {
      await inCameraRoll();
      // Rewriting the row cannot reset the camera-roll answer, which is asked live.
      await want(photo, quality: OfflineQuality.fullWithVideos);

      expect((await sut.storage()).spareOriginalBytes, 900);
    });
  });

  test("a video's playable file follows the same rule", () async {
    await want(video, quality: OfflineQuality.fullWithVideos);
    await hold(video, OfflineVariant.thumbnail, 10);
    await hold(video, OfflineVariant.preview, 90);
    await hold(video, OfflineVariant.video, 5000);

    expect((await sut.storage()).keptVideoBytes, 5000);

    await inCameraRoll(video);
    expect((await sut.storage()).spareVideoBytes, 5000);
  });

  test("a Live Photo's motion part follows it too, being a file of the photo", () async {
    await withMotion();
    await want(photo, quality: OfflineQuality.fullWithVideos);
    await hold(photo, OfflineVariant.video, 4000);

    expect((await sut.storage()).keptVideoBytes, 4000);

    await inCameraRoll();
    expect((await sut.storage()).spareVideoBytes, 4000);
  });

  test('the paged row asks the camera roll rather than remembering it', () async {
    await want(photo, quality: OfflineQuality.full);
    expect((await sut.page(limit: 10)).single.localCopy, isFalse);

    await inCameraRoll();
    expect((await sut.page(limit: 10)).single.localCopy, isTrue);
  });

  /// The token [photo]'s current thumbnail and preview end in, from its thumbhash upstream.
  Future<int> currentToken() async {
    final row = await (ctx.db.select(ctx.db.remoteAssetEntity)..where((asset) => asset.id.equals(photo))).getSingle();
    return offlineVersionToken(photo, row.thumbHash!);
  }

  test('a newer file of the same asset and variant replaces the old one, and says which it replaced', () async {
    final token = await currentToken();
    await sut.markHeld([
      OfflineHeldRow(name: 'old-preview', assetId: photo, variant: OfflineVariant.preview, token: 1, size: 90),
      OfflineHeldRow(name: 'old-thumbnail', assetId: photo, variant: OfflineVariant.thumbnail, token: 1, size: 10),
    ]);

    final superseded = await sut.markHeld([
      OfflineHeldRow(name: 'new-preview', assetId: photo, variant: OfflineVariant.preview, token: token, size: 80),
    ]);

    // The old thumbnail goes too: it shares the version, so the new preview shows it is outdated.
    expect(superseded, unorderedEquals([(name: 'old-preview', size: 90), (name: 'old-thumbnail', size: 10)]));
    expect((await sut.storage()).bytes, 80);
    expect(
      await sut.markHeld([
        OfflineHeldRow(name: 'new-preview', assetId: photo, variant: OfflineVariant.preview, token: token, size: 80),
      ]),
      isEmpty,
    );
  });

  test('a new thumbnail version also replaces the old preview, which nothing will ask for again', () async {
    final token = await currentToken();
    await sut.markHeld([
      OfflineHeldRow(name: 'old-thumbnail', assetId: photo, variant: OfflineVariant.thumbnail, token: 1, size: 10),
      OfflineHeldRow(name: 'old-preview', assetId: photo, variant: OfflineVariant.preview, token: 1, size: 90),
    ]);

    final superseded = await sut.markHeld([
      OfflineHeldRow(name: 'new-thumbnail', assetId: photo, variant: OfflineVariant.thumbnail, token: token, size: 12),
    ]);

    expect(superseded.map((file) => file.name), unorderedEquals(['old-thumbnail', 'old-preview']));
    expect((await sut.heldPage(limit: 10)).map((row) => row.name), ['new-thumbnail']);
    // One token per item again, which the index reads.
    expect((await sut.loadIndex()).single.token, token);
  });

  test('an old version landing after the new one does not take the new one away', () async {
    final token = await currentToken();
    // The new preview came in through the image path; a thumbnail queued before the edit lands after it.
    await sut.markHeld([
      OfflineHeldRow(name: 'new-preview', assetId: photo, variant: OfflineVariant.preview, token: token, size: 90),
    ]);
    final superseded = await sut.markHeld([
      OfflineHeldRow(name: 'old-thumbnail', assetId: photo, variant: OfflineVariant.thumbnail, token: 1, size: 10),
    ]);

    expect(superseded, isEmpty);
    expect((await sut.heldPage(limit: 10)).map((row) => row.name), unorderedEquals(['new-preview', 'old-thumbnail']));
  });

  test('a thumbnail and preview of the same version stand together', () async {
    final token = await currentToken();
    await sut.markHeld([
      OfflineHeldRow(name: 'thumbnail', assetId: photo, variant: OfflineVariant.thumbnail, token: token, size: 10),
    ]);
    final superseded = await sut.markHeld([
      OfflineHeldRow(name: 'preview', assetId: photo, variant: OfflineVariant.preview, token: token, size: 90),
    ]);

    expect(superseded, isEmpty);
    expect((await sut.heldPage(limit: 10)).length, 2);
  });

  test('of two versions in one batch the later stays, and the earlier is handed back to delete', () async {
    final superseded = await sut.markHeld([
      OfflineHeldRow(name: 'first', assetId: photo, variant: OfflineVariant.preview, token: 1, size: 90),
      OfflineHeldRow(name: 'second', assetId: photo, variant: OfflineVariant.preview, token: 2, size: 80),
    ]);

    expect(superseded, [(name: 'first', size: 90)]);
    expect((await sut.heldPage(limit: 10)).map((row) => row.name), ['second']);
  });

  test('files of locked items are found under the item and under their own name', () async {
    await sut.markHeld([
      OfflineHeldRow(name: 'under-item', assetId: photo, variant: OfflineVariant.preview, token: 1, size: 90),
      OfflineHeldRow(
        name: 'assets_${photo}_thumbnail_fullsize_00000000',
        assetId: 'assets_${photo}_thumbnail_fullsize_00000000',
        variant: OfflineVariant.original,
        token: 0,
        size: 900,
      ),
      OfflineHeldRow(name: 'other', assetId: video, variant: OfflineVariant.preview, token: 1, size: 90),
    ]);
    expect(await sut.heldOfLocked(), isEmpty);

    await (ctx.db.update(ctx.db.remoteAssetEntity)..where((row) => row.id.equals(photo))).write(
      const RemoteAssetEntityCompanion(visibility: Value(AssetVisibility.locked)),
    );

    expect(
      (await sut.heldOfLocked()).map((row) => row.name),
      unorderedEquals(['under-item', 'assets_${photo}_thumbnail_fullsize_00000000']),
    );
  });

  test('reads a synced asset\'s thumbhash, the version a merged asset\'s URLs name', () async {
    await (ctx.db.update(ctx.db.remoteAssetEntity)..where((row) => row.id.equals(photo))).write(
      const RemoteAssetEntityCompanion(thumbHash: Value('after-edit')),
    );

    expect(await sut.thumbHashOf(photo), 'after-edit');
    expect(await sut.thumbHashOf('not-synced'), isNull);
  });

  test('a row whose asset the server deleted still pages, so the passes that forget it can see it', () async {
    await want(photo, quality: OfflineQuality.full, onDemand: true);
    await (ctx.db.delete(ctx.db.remoteAssetEntity)..where((asset) => asset.id.equals(photo))).go();

    final row = (await sut.page(limit: 10)).single;
    expect(row.id, photo);
    expect(row.localCopy, isFalse);
  });

  test('a hand-fetched row is a spare throughout, local copy or not', () async {
    await want(photo, quality: OfflineQuality.fullWithVideos, onDemand: true);
    await holdWholePhoto(photo);

    final storage = await sut.storage();
    expect(storage.spareOriginalBytes, 900);
    expect(storage.sparePreviewBytes, 90);
    expect(storage.spareThumbnailBytes, 10);
  });

  /// Emptying the store keeps the selection; abandoning the mirror must take the decisions too, or the next sign-in
  /// downloads everything again.
  group('clearing', () {
    setUp(() async {
      await want(photo, quality: OfflineQuality.full);
      await holdWholePhoto(photo);
      await sut.addErrands([photo]);
      // Past the attempt limit, so it counts as abandoned and the assertions below are about something.
      for (var attempt = 0; attempt < 3; attempt++) {
        await sut.recordFailure('some-file');
      }
    });

    test('the files alone leaves what was asked for', () async {
      await sut.clearHeld();

      expect((await sut.storage()).bytes, 0);
      expect((await sut.page(limit: 10)).single.id, photo);
      expect(await sut.errands(), {photo});
      expect(await sut.abandonedCount(), 1);
    });

    test('a second launch keeps what the first gave up on', () async {
      await sut.ensureSchema();

      expect(await sut.abandonedCount(), 1);
    });

    test('the first launch after an upgrade forgets what older builds gave up on', () async {
      // What an install from before failures were told apart looks like: the rows, no record of having sorted them,
      // and no schema version.
      await ctx.db.customStatement("DELETE FROM $kOfflineSchema.meta WHERE key = 'failures_classified'");
      await ctx.db.customStatement('PRAGMA $kOfflineSchema.user_version = 0');

      await sut.ensureSchema();

      expect(await sut.abandonedCount(), 0);
    });

    test('the first launch after an upgrade drops the timeline cache older builds kept', () async {
      await ctx.db.customStatement('CREATE TABLE $kOfflineSchema.timeline_buckets (user_key TEXT PRIMARY KEY)');
      await ctx.db.customStatement('CREATE TABLE $kOfflineSchema.timeline_buckets_cleared (at INTEGER)');
      await ctx.db.customStatement('PRAGMA $kOfflineSchema.user_version = 0');

      await sut.ensureSchema();

      final tables = await ctx.db
          .customSelect("SELECT name FROM $kOfflineSchema.sqlite_master WHERE type = 'table'")
          .map((row) => row.read<String>('name'))
          .get();
      expect(tables, isNot(contains(startsWith('timeline_buckets'))));
    });

    test('a versioned file does not run the steps it has had again', () async {
      final version = await ctx.db.customSelect('PRAGMA $kOfflineSchema.user_version').getSingle();
      expect(version.read<int>('user_version'), OfflineFlagsRepository.schemaVersion);
      // Without the version, the missing marker would have the next launch forget these.
      await ctx.db.customStatement("DELETE FROM $kOfflineSchema.meta WHERE key = 'failures_classified'");

      await sut.ensureSchema();

      expect(await sut.abandonedCount(), 1);
    });

    test('a file from a newer build is left as it is', () async {
      await ctx.db.customStatement('PRAGMA $kOfflineSchema.user_version = 99');

      await sut.ensureSchema();

      final version = await ctx.db.customSelect('PRAGMA $kOfflineSchema.user_version').getSingle();
      expect(version.read<int>('user_version'), 99);
      expect(await sut.abandonedCount(), 1);
    });

    test('everything leaves nothing to re-derive from', () async {
      await sut.clearAll();

      expect((await sut.storage()).bytes, 0);
      expect(await sut.page(limit: 10), isEmpty);
      expect(await sut.errands(), isEmpty);
      expect(await sut.abandonedCount(), 0);
    });

    test('everything keeps the one-time upgrades done, so the next launch does not renumber new rows', () async {
      await sut.clearAll();
      // What the next sign-in writes, already in the current numbering.
      await want(photo, quality: OfflineQuality.preview);
      await want(video, quality: OfflineQuality.fullWithVideos, onDemand: true);

      await sut.ensureSchema();

      final rows = {for (final row in await sut.page(limit: 10)) row.id: row.quality};
      expect(rows, {photo: OfflineQuality.preview, video: OfflineQuality.fullWithVideos});
    });
  });

  /// Eviction: only spares, least recently used first, whole items at a time, never a pending *Save offline*.
  group('eviction', () {
    final day = DateTime.utc(2026, 10, 1);

    Future<void> holdAt(String id, OfflineVariant variant, int size, DateTime at) => sut.markHeld([
      OfflineHeldRow(name: '$id-${variant.name}', assetId: id, variant: variant, token: 1, size: size),
    ], at: at);

    test('offers spares only, never what a selection maintains', () async {
      await want(photo, quality: OfflineQuality.preview);
      await holdAt(photo, OfflineVariant.thumbnail, 10, day);
      await holdAt(photo, OfflineVariant.preview, 90, day);
      // Opened in the viewer: a full-size copy a previews selection does not ask for.
      await holdAt(photo, OfflineVariant.original, 900, day);

      final candidates = await sut.evictionCandidates(bytes: _everything);

      expect(candidates.map((row) => row.name), ['$photo-original']);
    });

    test('takes the least recently used item first, with all of its spares together', () async {
      // Browsed, nothing selects either.
      await holdAt(photo, OfflineVariant.thumbnail, 10, day);
      await holdAt(photo, OfflineVariant.preview, 90, day);
      await holdAt(video, OfflineVariant.thumbnail, 10, day.subtract(const Duration(days: 1)));

      final candidates = await sut.evictionCandidates(bytes: _everything);

      expect(candidates.map((row) => row.assetId), [video, photo, photo]);
    });

    test('a file shown again moves its item to the back', () async {
      await holdAt(photo, OfflineVariant.thumbnail, 10, day.subtract(const Duration(days: 1)));
      await holdAt(video, OfflineVariant.thumbnail, 10, day);

      await sut.touchHeld(['$photo-thumbnail'], day.add(const Duration(days: 1)));

      expect((await sut.evictionCandidates(bytes: _everything)).map((row) => row.assetId), [video, photo]);
    });

    test('an item counts as used when any of its spares was', () async {
      await holdAt(photo, OfflineVariant.thumbnail, 10, day.subtract(const Duration(days: 2)));
      await holdAt(photo, OfflineVariant.preview, 90, day.add(const Duration(days: 1)));
      await holdAt(video, OfflineVariant.thumbnail, 10, day);

      expect((await sut.evictionCandidates(bytes: 1)).map((row) => row.assetId), [video]);
    });

    test('offers whole items until the bytes asked for are covered, and no more', () async {
      await holdAt(photo, OfflineVariant.thumbnail, 10, day.subtract(const Duration(days: 1)));
      await holdAt(photo, OfflineVariant.preview, 90, day.subtract(const Duration(days: 1)));
      await holdAt(video, OfflineVariant.thumbnail, 10, day);

      // The oldest item crosses 50 on its own, files together.
      expect((await sut.evictionCandidates(bytes: 50)).map((row) => row.assetId), [photo, photo]);
      // Exactly its size is covered by it alone; one byte more needs the next.
      expect((await sut.evictionCandidates(bytes: 100)).map((row) => row.assetId), [photo, photo]);
      expect((await sut.evictionCandidates(bytes: 101)).map((row) => row.assetId), [photo, photo, video]);
    });

    test('skips an item whose save is still on its way, or the save evicts itself', () async {
      await want(photo, quality: kOfflineErrandQuality, onDemand: true);
      await sut.addErrands([photo]);
      await holdAt(photo, OfflineVariant.thumbnail, 10, day.subtract(const Duration(days: 30)));

      expect(await sut.evictionCandidates(bytes: _everything), isEmpty);

      // Once it has arrived, a hand-saved copy is a spare like any other.
      await sut.dropErrands([photo]);
      expect((await sut.evictionCandidates(bytes: _everything)).single.assetId, photo);
    });

    test('saving touches the copies already here', () async {
      await holdAt(photo, OfflineVariant.thumbnail, 10, day.subtract(const Duration(days: 1)));
      await holdAt(video, OfflineVariant.thumbnail, 10, day);

      await sut.touchAssets([photo], day.add(const Duration(days: 1)));

      expect((await sut.evictionCandidates(bytes: _everything)).map((row) => row.assetId), [video, photo]);
    });

    test('a file kept for no asset — a face — is a spare', () async {
      await sut.markHeld([
        const OfflineHeldRow(
          name: 'people_1_thumbnail_00000000',
          assetId: 'people_1_thumbnail_00000000',
          variant: OfflineVariant.thumbnail,
          token: 0,
          size: 5,
        ),
      ], at: day);

      final storage = await sut.storage();
      expect(storage.spareThumbnailBytes, 5);
      // Held, but not an item: nothing about it opens offline.
      expect(storage.availableAssets, 0);
      expect((await sut.evictionCandidates(bytes: _everything)).single.size, 5);
    });

    test('a store from before `used_at` gains it, and its files read as the oldest', () async {
      // An older build's table, with a file in it.
      await ctx.db.customStatement('ALTER TABLE $kOfflineSchema.held DROP COLUMN used_at');
      await ctx.db.customStatement('PRAGMA $kOfflineSchema.user_version = 0');
      await ctx.db.customStatement(
        "INSERT INTO $kOfflineSchema.held (name, asset_id, variant, token, size) VALUES ('old', '$video', 0, 1, 10)",
      );

      await sut.ensureSchema();
      await holdAt(photo, OfflineVariant.thumbnail, 10, day);

      expect((await sut.evictionCandidates(bytes: _everything)).map((row) => row.assetId), [video, photo]);
    });
  });

  /// The cleanup sheet's four kinds: a preview goes only once no full-size copy stays, a thumbnail once nothing bigger
  /// does.
  group('removing by kind', () {
    OfflineReclaim spares(Set<OfflineReclaimKind> kinds) =>
        OfflineReclaim({for (final kind in kinds) (OfflineReclaimBand.spares, kind)});

    // Browsed whole, nothing selects it: every file a spare.
    setUp(() => holdWholePhoto(photo));

    test('previews go on their own once the full-size copy is going, and the thumbnail stays', () async {
      final plan = await sut.reclaimPlan(what: spares({OfflineReclaimKind.originals, OfflineReclaimKind.previews}));

      expect(plan.bytes, 900 + 90);
      expect(plan.losingPreviews, 1);
      expect(plan.removedItems, 0);
      expect(plan.losingOriginals, 0);
    });

    test('a preview stays while the full-size copy does', () async {
      final plan = await sut.reclaimPlan(what: spares({OfflineReclaimKind.previews}));

      expect(plan.isEmpty, isTrue);
    });

    test('a thumbnail stays while a preview does', () async {
      final plan = await sut.reclaimPlan(what: spares({OfflineReclaimKind.originals, OfflineReclaimKind.thumbnails}));

      expect(plan.bytes, 900);
      expect(plan.losingOriginals, 1);
    });

    test('everything ticked removes the item, and says so once', () async {
      final plan = await sut.reclaimPlan();

      expect(plan.bytes, 1000);
      expect(plan.removedItems, 1);
      expect(plan.losingPreviews + plan.losingOriginals + plan.losingVideos, 0);
    });

    test('each cell gives up what it would actually take', () async {
      final covered = await sut.reclaimBytesByCell(
        spares({OfflineReclaimKind.originals, OfflineReclaimKind.previews, OfflineReclaimKind.thumbnails}),
      );

      expect(covered, {
        (OfflineReclaimBand.spares, OfflineReclaimKind.originals): 900,
        (OfflineReclaimBand.spares, OfflineReclaimKind.previews): 90,
        (OfflineReclaimBand.spares, OfflineReclaimKind.thumbnails): 10,
      });
    });

    test('an item with no thumbnail to fall back on is removed, not left with one', () async {
      // Opened from a search result: a preview and nothing smaller.
      await hold(video, OfflineVariant.preview, 90);

      final plan = await sut.reclaimPlan(what: spares({OfflineReclaimKind.originals, OfflineReclaimKind.previews}));

      // The photo keeps its thumbnail; the other keeps nothing.
      expect(plan.losingPreviews, 1);
      expect(plan.removedItems, 1);
    });

    test('a file kept for no asset counts its bytes, and is no item', () async {
      await sut.markHeld([
        const OfflineHeldRow(
          name: 'people_1_thumbnail_00000000',
          assetId: 'people_1_thumbnail_00000000',
          variant: OfflineVariant.thumbnail,
          token: 0,
          size: 5,
        ),
      ]);

      final plan = await sut.reclaimPlan(what: spares({OfflineReclaimKind.thumbnails}));

      expect(plan.bytes, 5);
      expect(plan.removedItems + plan.losingPreviews + plan.losingOriginals + plan.losingVideos, 0);
    });
  });

  group('the thumbnail rung', () {
    test('keeps the thumbnail as library and any preview as a spare', () async {
      await want(photo, quality: OfflineQuality.thumbnail);
      await hold(photo, OfflineVariant.thumbnail, 10);
      await hold(photo, OfflineVariant.preview, 90);

      // Apart, which is the point of two rows: the thumbnail is library, the preview a spare.
      final storage = await sut.storage();
      expect(storage.libraryThumbnailBytes, 10);
      expect(storage.libraryPreviewBytes, 0);
      expect(storage.sparePreviewBytes, 90);
      expect(storage.spareThumbnailBytes, 0);
      expect(storage.availableAssets, 1);
      // The cleanup sheet's cells say the same.
      expect(storage.bytesFor(OfflineReclaimBand.maintained, OfflineReclaimKind.thumbnails), 10);
      expect(storage.bytesFor(OfflineReclaimBand.spares, OfflineReclaimKind.previews), 90);

      final plan = await sut.reclaimPlan();
      expect(plan.bytes, 90);
      expect(plan.files, 1);
      // Left with its thumbnail: in the grid, not gone.
      expect(plan.losingPreviews, 1);
      expect(plan.removedItems, 0);
    });

    test('is missing nothing once its thumbnail is here', () async {
      await want(photo, quality: OfflineQuality.thumbnail);
      expect(await sut.hasMissingBase(), isTrue);

      await hold(photo, OfflineVariant.thumbnail, 10);
      expect(await sut.hasMissingBase(), isFalse);
    });

    test('a rung above it still misses its preview', () async {
      await want(photo, quality: OfflineQuality.preview);
      await hold(photo, OfflineVariant.thumbnail, 10);
      expect(await sut.hasMissingBase(), isTrue);
    });

    test(
      'the first launch after it went in moves older codes up one, so a preview is not read as a thumbnail',
      () async {
        // What an install from before the rung looks like: previews stored as 1, and no record of having moved them.
        await want(photo, quality: OfflineQuality.preview);
        await want(video, quality: OfflineQuality.fullWithVideos);
        await ctx.db.customStatement('UPDATE $kOfflineSchema.wanted SET quality = quality - 1');
        await ctx.db.customStatement("DELETE FROM $kOfflineSchema.meta WHERE key = 'rungs_renumbered'");
        await ctx.db.customStatement('PRAGMA $kOfflineSchema.user_version = 0');

        await sut.ensureSchema();
        final rows = {for (final row in await sut.page(limit: 10)) row.id: row.quality};
        expect(rows, {photo: OfflineQuality.preview, video: OfflineQuality.fullWithVideos});

        // And only once.
        await sut.ensureSchema();
        final again = {for (final row in await sut.page(limit: 10)) row.id: row.quality};
        expect(again, rows);
      },
    );
  });

  // --------------------------------------------------------------------------- Deriving

  /// `derive` is `OfflinePolicy.resolve` in SQL. Checked against it for every combination of library rung, included
  /// album and excluded album.
  group('the derive agrees with the policy it implements', () {
    late MediumRepositoryContext ctx;
    late OfflineFlagsRepository flags;
    late String ownerId;

    setUp(() async {
      ctx = MediumRepositoryContext();
      flags = await ctx.offlineFlags();
      ownerId = (await ctx.newUser()).id;
      await flags.setUpstreamComplete();
    });

    tearDown(() async {
      await ctx.dispose();
    });

    test('over every combination of library rung, included album and exclusion', () async {
      final included = await ctx.newRemoteAlbum(ownerId: ownerId);
      final alsoIncluded = await ctx.newRemoteAlbum(ownerId: ownerId);
      final excluded = await ctx.newRemoteAlbum(ownerId: ownerId);

      // Every subset of the three albums.
      final memberships = <String, List<String>>{};
      for (var mask = 0; mask < 8; mask++) {
        final asset = await ctx.newRemoteAsset(ownerId: ownerId);
        final albums = [
          if (mask & 1 != 0) included.id,
          if (mask & 2 != 0) alsoIncluded.id,
          if (mask & 4 != 0) excluded.id,
        ];
        for (final album in albums) {
          await ctx.newRemoteAlbumAsset(albumId: album, assetId: asset.id);
        }
        memberships[asset.id] = albums;
      }

      for (final library in [null, ...OfflineQuality.values.where((quality) => quality.isWanted)]) {
        for (final rung in OfflineQuality.values.where((quality) => quality.isWanted)) {
          final policy = OfflinePolicy(
            library: library,
            albums: {included.id: rung, alsoIncluded.id: OfflineQuality.thumbnail},
            excluded: {excluded.id},
          );

          await flags.derive(policy, DateTime.now());
          final rows = {for (final want in await flags.page(limit: 100)) want.id: want.quality};

          for (final entry in memberships.entries) {
            expect(
              rows[entry.key],
              policy.resolve(entry.value),
              reason: 'library=$library rung=$rung albums=${entry.value}',
            );
          }
        }
      }
    });

    test('a hand-fetched row survives a selection that covers nothing', () async {
      final asset = await ctx.newRemoteAsset(ownerId: ownerId);
      await flags.set([
        OfflineFlagRow(
          id: asset.id,
          quality: OfflineQuality.fullWithVideos,
          createdAt: DateTime.now(),
          touchedAt: DateTime.now(),
          onDemand: true,
        ),
      ]);

      await flags.derive(OfflinePolicy.empty, DateTime.now());

      // Nothing on the settings screen ever asked for it, so no change to the settings may take it away.
      expect((await flags.page(limit: 10)).map((want) => want.id), contains(asset.id));
    });

    test('a hand-fetched row a selection covers at the same rung becomes the selection\'s', () async {
      final asset = await ctx.newRemoteAsset(ownerId: ownerId);
      await flags.set([
        OfflineFlagRow(
          id: asset.id,
          quality: kOfflineErrandQuality,
          createdAt: DateTime.now(),
          touchedAt: DateTime.now(),
          onDemand: true,
        ),
      ]);

      await flags.derive(const OfflinePolicy(library: kOfflineErrandQuality), DateTime.now());

      // Still marked by hand, its files would count as spares, and "free up space" would take what the library keeps.
      final row = await ctx.db
          .customSelect(
            'SELECT quality, on_demand FROM $kOfflineSchema.wanted WHERE asset_id = ?',
            variables: [Variable(asset.id)],
          )
          .getSingle();
      expect(row.read<int>('quality'), kOfflineErrandQuality.code);
      expect(row.read<int>('on_demand'), 0);
    });

    test('a pending errand outlives the selection that covered it', () async {
      final asset = await ctx.newRemoteAsset(ownerId: ownerId);
      const policy = OfflinePolicy(library: OfflineQuality.preview);
      await flags.derive(policy, DateTime.now());
      await flags.addErrands([asset.id]);

      await flags.derive(OfflinePolicy.empty, DateTime.now());

      final row = await ctx.db
          .customSelect(
            'SELECT quality, on_demand, pinned FROM $kOfflineSchema.wanted WHERE asset_id = ?',
            variables: [Variable(asset.id)],
          )
          .getSingle();
      expect(row.read<int>('quality'), kOfflineErrandQuality.code);
      expect(row.read<int>('on_demand'), 1);
      expect(row.read<int>('pinned'), 1);
    });

    test('an unchanged decision keeps the stamp its own change gave it', () async {
      // `touched_at` orders the download queue, so unchanged rows must keep theirs.
      await ctx.newRemoteAsset(ownerId: ownerId);
      const policy = OfflinePolicy(library: OfflineQuality.full);

      await flags.derive(policy, DateTime.fromMillisecondsSinceEpoch(1000000000000));
      final first = (await flags.page(limit: 10)).single.touchedAt;

      await flags.derive(policy, DateTime.fromMillisecondsSinceEpoch(2000000000000));

      expect((await flags.page(limit: 10)).single.touchedAt, first);
    });

    test('half-synced, the derive adds and raises but drops and lowers nothing', () async {
      final album = await ctx.newRemoteAlbum(ownerId: ownerId);
      final inAlbum = await ctx.newRemoteAsset(ownerId: ownerId);
      final outside = await ctx.newRemoteAsset(ownerId: ownerId);
      await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: inAlbum.id);
      final policy = OfflinePolicy(library: OfflineQuality.preview, albums: {album.id: OfflineQuality.full});
      await flags.derive(policy, DateTime.now());

      // Upstream re-syncing: assets are back, their album links are not yet.
      await ctx.db.delete(ctx.db.remoteAlbumAssetEntity).go();
      final arrived = await ctx.newRemoteAsset(ownerId: ownerId);
      await OfflineFlagsRepository.noteUpstreamReset(ctx.db);
      await flags.derive(policy, DateTime.now());

      final rows = {for (final want in await flags.page(limit: 10)) want.id: want.quality};
      expect(rows[inAlbum.id], OfflineQuality.full, reason: 'not lowered to the library rung');
      expect(rows[outside.id], OfflineQuality.preview);
      expect(rows[arrived.id], OfflineQuality.preview, reason: 'new items are still added');

      // Once complete, the same state is taken at its word.
      await flags.setUpstreamComplete();
      await flags.derive(policy, DateTime.now());
      expect((await flags.page(limit: 10)).firstWhere((want) => want.id == inAlbum.id).quality, OfflineQuality.preview);
    });

    test('half-synced, a selection that covers nothing drops nothing', () async {
      await ctx.newRemoteAsset(ownerId: ownerId);
      await flags.derive(const OfflinePolicy(library: OfflineQuality.full), DateTime.now());

      await OfflineFlagsRepository.noteUpstreamReset(ctx.db);
      await flags.derive(OfflinePolicy.empty, DateTime.now());

      expect(await flags.page(limit: 10), hasLength(1));
    });

    test('a rung that moves takes a fresh stamp', () async {
      final asset = await ctx.newRemoteAsset(ownerId: ownerId);
      await flags.derive(
        const OfflinePolicy(library: OfflineQuality.preview),
        DateTime.fromMillisecondsSinceEpoch(1000000000000),
      );
      final first = (await flags.page(limit: 10)).single.touchedAt;

      await flags.derive(
        const OfflinePolicy(library: OfflineQuality.full),
        DateTime.fromMillisecondsSinceEpoch(2000000000000),
      );
      final row = (await flags.page(limit: 10)).single;

      expect(row.quality, OfflineQuality.full);
      expect(row.touchedAt, greaterThan(first));
      expect(asset.id, row.id);
    });
  });

  // --------------------------------------------------------------------------- Upstream readiness

  group('upstream readiness', () {
    late MediumRepositoryContext ctx;
    late OfflineFlagsRepository flags;

    setUp(() async {
      ctx = MediumRepositoryContext();
      flags = await ctx.offlineFlags();
    });

    tearDown(() async {
      await ctx.dispose();
    });

    test('vouches only for reads that a reset did not overtake', () async {
      await flags.setUpstreamComplete();

      final read = await flags.vouch(() async {
        // A sign-out landing while the reads run.
        await SyncStreamRepository(ctx.db).reset();
        return 'gone';
      });

      expect(read.complete, isFalse);
      expect(read.ifComplete, isNull);
    });

    test('hands the reads over once upstream is complete', () async {
      expect((await flags.vouch(() async => 'gone')).ifComplete, isNull);

      await flags.setUpstreamComplete();

      expect((await flags.vouch(() async => 'gone')).ifComplete, 'gone');
    });

    test('starts closed and opens once', () async {
      expect((await flags.vouch(() async {})).complete, isFalse);
      expect(await flags.setUpstreamComplete(), isTrue);
      expect(await flags.setUpstreamComplete(), isFalse);
      expect((await flags.vouch(() async {})).complete, isTrue);
    });

    test('starts open on a library a build without it already synced', () async {
      final synced = MediumRepositoryContext();
      addTearDown(synced.dispose);
      await synced.newRemoteAsset(ownerId: (await synced.newUser()).id);

      expect((await (await synced.offlineFlags()).vouch(() async {})).complete, isTrue);
    });

    test("upstream's reset closes it, as sign-out and a server reset do", () async {
      await flags.setUpstreamComplete();

      await SyncStreamRepository(ctx.db).reset();

      expect((await flags.vouch(() async {})).complete, isFalse);
    });

    test('counts every reset of upstream', () async {
      expect(await flags.resetGeneration(), 0);

      await SyncStreamRepository(ctx.db).reset();
      await OfflineFlagsRepository.noteUpstreamReset(ctx.db);

      expect(await flags.resetGeneration(), 2);
    });

    test('a sync opens it only if no reset came after it started', () async {
      final atStart = await flags.resetGeneration();
      // A sign-out landing after the sync finished, before it is recorded.
      await SyncStreamRepository(ctx.db).reset();

      expect(await flags.setUpstreamComplete(ifGeneration: atStart), isFalse);
      expect((await flags.vouch(() async {})).complete, isFalse);

      // The next sync, started after the reset, opens it.
      expect(await flags.setUpstreamComplete(ifGeneration: await flags.resetGeneration()), isTrue);
      expect((await flags.vouch(() async {})).complete, isTrue);
    });

    test('forgetting the mirror keeps the reset count, which describes upstream', () async {
      await OfflineFlagsRepository.noteUpstreamReset(ctx.db);

      await flags.clearAll();

      expect(await flags.resetGeneration(), 1);
    });

    test('forgetting the mirror keeps it, since it describes upstream', () async {
      await flags.setUpstreamComplete();

      await flags.clearAll();

      expect((await flags.vouch(() async {})).complete, isTrue);
    });

    test(
      "upstream's reset still wipes when the mirror cannot take the write, so sign-out never depends on it",
      () async {
        await ctx.newRemoteAsset(ownerId: (await ctx.newUser()).id);
        await ctx.db.customStatement(
          'CREATE TRIGGER $kOfflineSchema.refuse BEFORE DELETE ON meta BEGIN SELECT RAISE(ABORT, \'refused\'); END',
        );

        await SyncStreamRepository(ctx.db).reset();

        expect(await ctx.db.select(ctx.db.remoteAssetEntity).get(), isEmpty);
      },
    );

    test("upstream's reset works on a connection without the fork's schema", () async {
      final plain = MediumRepositoryContext();
      addTearDown(plain.dispose);

      await SyncStreamRepository(plain.db).reset();
    });
  });

  // --------------------------------------------------------------------------- Opening the file

  group('an unreadable offline database', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('offline_prepare');
      path = '${dir.path}/$kOfflineDatabaseName';
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('is set aside, so the app still opens', () async {
      File(path).writeAsStringSync('not a database, just bytes that happen to be here' * 100);

      await OfflineFlagsRepository.prepareFile(path);

      expect(File(path).existsSync(), isFalse);
      expect(File('$path.corrupt').existsSync(), isTrue);

      // What bootstrap does next: attach a fresh file and bring the schema up.
      final ctx = MediumRepositoryContext();
      addTearDown(ctx.dispose);
      await ctx.db.customStatement("ATTACH DATABASE '$path' AS $kOfflineSchema");
      final flags = await OfflineFlagsRepository.forConnection(ctx.db);
      expect(await flags.heldBytes(), 0);
    });

    test('is set aside too when the damage is past the schema, once a query has found it', () async {
      final first = MediumRepositoryContext();
      await first.db.customStatement("ATTACH DATABASE '$path' AS $kOfflineSchema");
      final healthy = await OfflineFlagsRepository.forConnection(first.db, path: path);
      await healthy.set([
        for (var i = 0; i < 2000; i++)
          OfflineFlagRow(
            id: 'asset-$i',
            quality: OfflineQuality.full,
            createdAt: DateTime(2020),
            touchedAt: DateTime(2020),
          ),
      ]);
      await first.dispose();
      // Every page but the first, which holds the schema, so opening the file still works.
      final bytes = File(path).readAsBytesSync();
      bytes.fillRange(4096, bytes.length, 0xA5);
      File(path).writeAsBytesSync(bytes);

      await OfflineFlagsRepository.prepareFile(path);
      expect(File('$path.corrupt').existsSync(), isFalse, reason: 'opening reads only the schema');

      final second = MediumRepositoryContext();
      await second.db.customStatement("ATTACH DATABASE '$path' AS $kOfflineSchema");
      final damaged = await OfflineFlagsRepository.forConnection(second.db, path: path);
      await expectLater(damaged.page(limit: 10), throwsA(anything));
      await second.dispose();

      await OfflineFlagsRepository.prepareFile(path);
      expect(File('$path.corrupt').existsSync(), isTrue);
      expect(File(path).existsSync(), isFalse);
      expect(File('$path.unreadable').existsSync(), isFalse, reason: 'acted on once');
    });

    test('is left in place while another connection has it open, and set aside once it is closed', () async {
      final other = MediumRepositoryContext();
      await other.db.customStatement("ATTACH DATABASE '$path' AS $kOfflineSchema");
      await (await OfflineFlagsRepository.forConnection(other.db)).setUpstreamComplete();
      File('$path.unreadable').createSync();

      await OfflineFlagsRepository.prepareFile(path);
      expect(File(path).existsSync(), isTrue);
      expect(File('$path.unreadable').existsSync(), isTrue, reason: 'tried again at the next launch');

      await other.dispose();
      await OfflineFlagsRepository.prepareFile(path);
      expect(File('$path.corrupt').existsSync(), isTrue);
    });

    test('while a healthy one is left alone', () async {
      final ctx = MediumRepositoryContext();
      await ctx.db.customStatement("ATTACH DATABASE '$path' AS $kOfflineSchema");
      final flags = await OfflineFlagsRepository.forConnection(ctx.db);
      await flags.setUpstreamComplete();
      await ctx.dispose();

      await OfflineFlagsRepository.prepareFile(path);

      expect(File('$path.corrupt').existsSync(), isFalse);
      final again = MediumRepositoryContext();
      addTearDown(again.dispose);
      await again.db.customStatement("ATTACH DATABASE '$path' AS $kOfflineSchema");
      expect((await (await OfflineFlagsRepository.forConnection(again.db)).vouch(() async {})).complete, isTrue);
    });
  });
}
