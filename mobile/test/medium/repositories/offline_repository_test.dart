/// immich-sync fork — which assets the mirror is allowed to store (FORK.md §3.2.1).
///
/// The filter is one expression shared by every query the reconciler pages, so a value missing from it is not a cosmetic
/// bug: the pass wants files that cannot exist and asks for them on every pass, for good. That is what hidden assets did
/// — the video half of a Live Photo, which upstream never generates a thumbnail for.
library;

// `hide isNull`, because drift and the matcher library both define that name and this file uses the matcher. Drift is
// needed for the `&` between two column predicates, which is an extension rather than a plain operator, so a `show`
// list would have to name the extension instead of anything visible at the call site.
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/user/user.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/offline.repository.dart';
import 'package:immich_mobile/utils/option.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late OfflineRepository sut;

  // Every asset needs one, because `remote_asset_entity.owner_id` is a foreign key and `newRemoteAsset` defaults it to
  // a fresh UUID that references nothing. Without an owner the whole file fails in `setUp` with a constraint error,
  // which is what it used to do.
  late UserEntityData owner;

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = OfflineRepository(ctx.db);
    owner = await ctx.newUser();
  });

  Future<RemoteAssetEntityData> newAsset({
    AssetVisibility? visibility,
    AssetType? type,
    DateTime? deletedAt,
    String? livePhotoVideoId,
    String? checksum,
    bool? isEdited,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? thumbHash,
  }) => ctx.newRemoteAsset(
    ownerId: owner.id,
    visibility: visibility,
    type: type,
    deletedAt: deletedAt,
    livePhotoVideoId: livePhotoVideoId,
    checksum: checksum,
    isEdited: isEdited,
    createdAt: createdAt,
    updatedAt: updatedAt,
    thumbHash: thumbHash,
  );

  tearDown(() async {
    await ctx.dispose();
  });

  Future<Set<String>> storableIds() async {
    final page = await sut.allAssets(limit: 100);
    return {for (final candidate in page) candidate.id};
  }

  group('what can be stored', () {
    test('a plain timeline asset can', () async {
      final asset = await newAsset(visibility: AssetVisibility.timeline);

      expect(await storableIds(), contains(asset.id));
    });

    test('an archived one can, since it is still shown and still has thumbnails', () async {
      final asset = await newAsset(visibility: AssetVisibility.archive);

      expect(await storableIds(), contains(asset.id));
    });

    test('a hidden one cannot: upstream skips thumbnail generation for it, so it is a 404 for ever', () async {
      final hidden = await newAsset(visibility: AssetVisibility.hidden, type: AssetType.video);

      expect(await storableIds(), isNot(contains(hidden.id)));
    });

    test('a locked one cannot, or its bytes would be readable outside the PIN gate', () async {
      final locked = await newAsset(visibility: AssetVisibility.locked);

      expect(await storableIds(), isNot(contains(locked.id)));
    });

    test('a trashed one cannot', () async {
      final trashed = await newAsset(deletedAt: DateTime.utc(2026, 8, 20));

      expect(await storableIds(), isNot(contains(trashed.id)));
    });

    test('the video half of a Live Photo is left behind while the photo itself is kept', () async {
      // The pair as the server holds it: the photo is visible and points at the video, which is hidden.
      final video = await newAsset(visibility: AssetVisibility.hidden, type: AssetType.video);
      final photo = await newAsset(
        visibility: AssetVisibility.timeline,
        type: AssetType.image,
        livePhotoVideoId: video.id,
      );

      final storable = await storableIds();
      expect(storable, contains(photo.id));
      expect(storable, isNot(contains(video.id)));
    });

    test('details are refused for a hidden asset too, so a decision already made stops being fetched', () async {
      final hidden = await newAsset(visibility: AssetVisibility.hidden, type: AssetType.video);
      final visible = await newAsset(visibility: AssetVisibility.timeline);

      // `detailsFor` is what the walk asks per page; an id it will not resolve is counted as unavailable rather than
      // queued (FORK.md §3.3).
      final details = await sut.detailsFor([hidden.id, visible.id]);

      expect(details.keys, [visible.id]);
    });
  });

  group('a Live Photo is one item', () {
    test('the photo carries the id of its motion part, so its file can be fetched under the photo', () async {
      final video = await newAsset(visibility: AssetVisibility.hidden, type: AssetType.video);
      final photo = await newAsset(type: AssetType.image, livePhotoVideoId: video.id);

      final details = await sut.detailsFor([photo.id]);

      expect(details[photo.id]!.motionVideoId, video.id);
      expect(details[photo.id]!.isImage, isTrue);
    });

    test('an ordinary photo has none', () async {
      final photo = await newAsset(type: AssetType.image);

      expect((await sut.detailsFor([photo.id]))[photo.id]!.motionVideoId, isNull);
    });

    test('candidates carry it too, since the derivation records it on the row', () async {
      final video = await newAsset(visibility: AssetVisibility.hidden, type: AssetType.video);
      final photo = await newAsset(type: AssetType.image, livePhotoVideoId: video.id);

      final candidates = await sut.allAssets(limit: 100);

      expect(candidates.singleWhere((c) => c.id == photo.id).motionVideoId, video.id);
    });

    test('hiddenIds names the halves a stale decision was made about', () async {
      final video = await newAsset(visibility: AssetVisibility.hidden, type: AssetType.video);
      final photo = await newAsset(type: AssetType.image, livePhotoVideoId: video.id);
      final trashed = await newAsset(deletedAt: DateTime.utc(2026, 8, 20));

      // The trashed one must *not* be named: the trash is undoable, so its decision is blocked rather than stale.
      expect(await sut.hiddenIds([video.id, photo.id, trashed.id]), {video.id});
    });
  });

  test('lockedIds names only the locked folder, not the trash or what has not synced yet', () async {
    final locked = await newAsset(visibility: AssetVisibility.locked);
    final trashed = await newAsset(deletedAt: DateTime.utc(2026, 8, 20));
    final visible = await newAsset();

    expect(await sut.lockedIds([locked.id, trashed.id, visible.id, 'not-synced-yet']), {locked.id});
  });

  group('an album the selection names but upstream lost', () {
    test('existingAlbumIds keeps the ones that are still there and names nothing else', () async {
      final album = await ctx.newRemoteAlbum(ownerId: owner.id);

      final alive = await sut.existingAlbumIds([album.id, 'deleted-album-id']);

      expect(alive, {album.id});
    });

    test('an empty album is still alive — it just has no members', () async {
      // The distinction the fix turns on: `albumAssetCounts` reads the link table, so an empty album is missing from it
      // too. Forgetting one of those would silently discard a selection the user made.
      final empty = await ctx.newRemoteAlbum(ownerId: owner.id);

      expect(await sut.albumAssetCounts(), isNot(contains(empty.id)));
      expect(await sut.existingAlbumIds([empty.id]), {empty.id});
    });

    test("a deleted album's photos are only reachable from the library, not from the album", () async {
      // What made deleting an excluded album a no-op: the derivation walks the album, and the album is gone.
      final album = await ctx.newRemoteAlbum(ownerId: owner.id);
      final asset = await newAsset();
      await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: asset.id);
      await (ctx.db.delete(ctx.db.remoteAlbumEntity)..where((row) => row.id.equals(album.id))).go();

      expect(await sut.assetsInAlbums([album.id], limit: 100), isEmpty);
      expect((await sut.allAssets(limit: 100)).map((c) => c.id), contains(asset.id));
    });
  });

  group('what the phone already holds', () {
    Future<void> localCopyOf(String checksum) => ctx.newLocalAsset(checksum: checksum);

    test('a photo with a camera-roll copy is reported as such', () async {
      final remote = await newAsset();
      await localCopyOf(remote.checksum);

      final details = await sut.detailsFor([remote.id]);

      expect(details[remote.id]!.hasLocalCopy, isTrue);
    });

    test('a photo with no matching checksum is not', () async {
      final remote = await newAsset();
      await ctx.newLocalAsset(checksum: 'something-else');

      expect((await sut.detailsFor([remote.id]))[remote.id]!.hasLocalCopy, isFalse);
    });

    test('a local copy is usable, so the mirror may skip the expensive files', () async {
      final remote = await newAsset();
      await localCopyOf(remote.checksum);

      expect((await sut.detailsFor([remote.id]))[remote.id]!.localCopyUsable, isTrue);
    });

    test('an edited photo renders from the server, so its local copy is not usable', () async {
      // `_shouldUseLocalAsset` ends in `&& !asset.isEdited`: the local file is the pre-edit picture.
      final remote = await newAsset(isEdited: true);
      await localCopyOf(remote.checksum);

      final asset = (await sut.detailsFor([remote.id]))[remote.id]!;

      expect(asset.hasLocalCopy, isTrue);
      expect(asset.localCopyUsable, isFalse);
    });

    test('Prefer remote images does not change it: one copy per device either way', () async {
      // That setting is about which copy to decode while online, not about whether the phone has the photo.
      final remote = await newAsset();
      await localCopyOf(remote.checksum);

      expect((await sut.detailsFor([remote.id]))[remote.id]!.localCopyUsable, isTrue);
    });
  });

  /// What tells the mirror it has work to do.
  ///
  /// This replaced a fingerprint of upstream — asset count, album-link count, `MAX(updated_at)` — which could not see
  /// an asset row change **in place**, and so did not notice an edit being applied or undone. `updated_at` is fed from
  /// `fileModifiedAt` (`sync_stream.repository.dart`), making it a property of the photograph rather than a clock, and
  /// the count is over every row, so trashing did not move it either.
  group('what wakes a pass', () {
    test('an edit reverted in place, which moves no count and no timestamp', () async {
      final edited = await newAsset(isEdited: true);
      final before = await sut.assetCount();
      final updatedAt = (await (ctx.db.select(ctx.db.remoteAssetEntity)
                ..where((row) => row.id.equals(edited.id)))
              .getSingle())
          .updatedAt;

      final woken = expectLater(sut.watchRemote(), emits(anything));
      await (ctx.db.update(ctx.db.remoteAssetEntity)..where((row) => row.id.equals(edited.id))).write(
        const RemoteAssetEntityCompanion(isEdited: Value(false)),
      );
      await woken;

      final after = await (ctx.db.select(ctx.db.remoteAssetEntity)..where((row) => row.id.equals(edited.id)))
          .getSingle();
      expect(after.isEdited, isFalse);
      expect(after.updatedAt, updatedAt, reason: 'the column upstream fills from fileModifiedAt does not move');
      expect(await sut.assetCount(), before, reason: 'nothing appeared or vanished');
    });

    test('an asset joining an album, which the link count alone could miss', () async {
      final album = await ctx.newRemoteAlbum(ownerId: owner.id);
      final asset = await newAsset();

      final woken = expectLater(sut.watchRemote(), emits(anything));
      await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: asset.id);

      await woken;
    });

    test('a camera-roll row being hashed, which moves no count at all', () async {
      // The write that decides whether the mirror owes an item a full-size copy, and the one a fingerprint of counts
      // was blindest to: a checksum arriving on a row that was already there.
      final local = await ctx.newLocalAsset(checksumOption: const Option.none());

      final woken = expectLater(sut.watchLocalAssets(), emits(anything));
      await (ctx.db.update(ctx.db.localAssetEntity)..where((row) => row.id.equals(local.id))).write(
        LocalAssetEntityCompanion(checksum: .new((await newAsset()).checksum)),
      );

      await woken;
    });
  });
}
