/// immich-sync fork: which assets the mirror may store. A value missing from the filter means files that can never be
/// fetched are asked for on every pass, as hidden Live Photo halves once were.
library;

// `hide isNull`: the matcher library defines it too.
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.drift.dart';
import 'package:immich_mobile/data/db/main/table/user/user.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/offline.repository.dart';
import 'package:immich_mobile/utils/option.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late OfflineRepository sut;

  // Assets need an owner, since `owner_id` is a foreign key.
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
    final ids = await ctx.db.remoteAssetEntity.select().map((row) => row.id).get();
    return (await sut.detailsFor(ids)).keys.toSet();
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

      // An id `detailsFor` will not resolve is counted as unavailable rather than queued.
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

    test('hiddenIds names the halves a stale decision was made about', () async {
      final video = await newAsset(visibility: AssetVisibility.hidden, type: AssetType.video);
      final photo = await newAsset(type: AssetType.image, livePhotoVideoId: video.id);
      final trashed = await newAsset(deletedAt: DateTime.utc(2026, 8, 20));

      // The trashed one must *not* be named: the trash is undoable, so its decision is blocked rather than stale.
      expect(await sut.hiddenIds([video.id, photo.id, trashed.id]), {video.id});
    });
  });

  test("sizesOf reads the originals' sizes, a Live Photo's motion part and the edit flag", () async {
    final motion = await newAsset(type: AssetType.video);
    final live = await newAsset(type: AssetType.image, livePhotoVideoId: motion.id);
    final edited = await newAsset(type: AssetType.image, isEdited: true);
    final unsynced = await newAsset(type: AssetType.image);
    for (final (id, size) in [(live.id, 3000000), (motion.id, 9000000), (edited.id, 4000000)]) {
      await ctx.db
          .into(ctx.db.remoteExifEntity)
          .insert(RemoteExifEntityCompanion.insert(assetId: id, fileSize: Value(size)));
    }

    final sizes = await sut.sizesOf([live.id, edited.id, unsynced.id, 'gone']);

    expect(sizes[live.id], (original: 3000000, motion: 9000000, isEdited: false));
    expect(sizes[edited.id], (original: 4000000, motion: 0, isEdited: true));
    // No EXIF yet: unknown, not zero bytes to fetch.
    expect(sizes[unsynced.id], (original: 0, motion: 0, isEdited: false));
    expect(sizes.containsKey('gone'), isFalse);
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
      // `albumAssetCounts` reads the link table, so an empty album is missing from it.
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

      expect(await sut.assetsInAlbum(album.id), isEmpty);
      expect(await storableIds(), contains(asset.id));
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

  /// What tells the mirror it has work to do: table writes, which also catch in-place changes such as an edit or a
  /// trashing.
  group('what wakes a pass', () {
    test('an edit reverted in place, which moves no count and no timestamp', () async {
      final edited = await newAsset(isEdited: true);
      final before = await sut.assetCount();
      final updatedAt = (await (ctx.db.select(
        ctx.db.remoteAssetEntity,
      )..where((row) => row.id.equals(edited.id))).getSingle()).updatedAt;

      final woken = expectLater(sut.watchRemote(), emits(anything));
      await (ctx.db.update(
        ctx.db.remoteAssetEntity,
      )..where((row) => row.id.equals(edited.id))).write(const RemoteAssetEntityCompanion(isEdited: Value(false)));
      await woken;

      final after = await (ctx.db.select(
        ctx.db.remoteAssetEntity,
      )..where((row) => row.id.equals(edited.id))).getSingle();
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
      // A checksum arriving on an existing row decides whether the mirror needs a full-size copy.
      final local = await ctx.newLocalAsset(checksumOption: const Option.none());

      final woken = expectLater(sut.watchLocalAssets(), emits(anything));
      await (ctx.db.update(ctx.db.localAssetEntity)..where((row) => row.id.equals(local.id))).write(
        LocalAssetEntityCompanion(checksum: .new((await newAsset()).checksum)),
      );

      await woken;
    });
  });
}
