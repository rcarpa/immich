/// immich-sync fork — which assets the mirror is allowed to store (FORK.md §3.2.1).
///
/// The filter is one expression shared by every query the reconciler pages, so a value missing from it is not a cosmetic
/// bug: the pass wants files that cannot exist and asks for them on every pass, for good. That is what hidden assets did
/// — the video half of a Live Photo, which upstream never generates a thumbnail for.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/offline.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late OfflineRepository sut;

  setUp(() {
    ctx = MediumRepositoryContext();
    sut = OfflineRepository(ctx.db);
  });

  tearDown(() async {
    await ctx.dispose();
  });

  Future<Set<String>> storableIds() async {
    final page = await sut.allAssets(limit: 100);
    return {for (final candidate in page) candidate.id};
  }

  group('what can be stored', () {
    test('a plain timeline asset can', () async {
      final asset = await ctx.newRemoteAsset(visibility: AssetVisibility.timeline);

      expect(await storableIds(), contains(asset.id));
    });

    test('an archived one can, since it is still shown and still has thumbnails', () async {
      final asset = await ctx.newRemoteAsset(visibility: AssetVisibility.archive);

      expect(await storableIds(), contains(asset.id));
    });

    test('a hidden one cannot: upstream skips thumbnail generation for it, so it is a 404 for ever', () async {
      final hidden = await ctx.newRemoteAsset(visibility: AssetVisibility.hidden, type: AssetType.video);

      expect(await storableIds(), isNot(contains(hidden.id)));
    });

    test('a locked one cannot, or its bytes would be readable outside the PIN gate', () async {
      final locked = await ctx.newRemoteAsset(visibility: AssetVisibility.locked);

      expect(await storableIds(), isNot(contains(locked.id)));
    });

    test('a trashed one cannot', () async {
      final trashed = await ctx.newRemoteAsset(deletedAt: DateTime.utc(2026, 8, 20));

      expect(await storableIds(), isNot(contains(trashed.id)));
    });

    test('the video half of a Live Photo is left behind while the photo itself is kept', () async {
      // The pair as the server holds it: the photo is visible and points at the video, which is hidden.
      final video = await ctx.newRemoteAsset(visibility: AssetVisibility.hidden, type: AssetType.video);
      final photo = await ctx.newRemoteAsset(
        visibility: AssetVisibility.timeline,
        type: AssetType.image,
        livePhotoVideoId: video.id,
      );

      final storable = await storableIds();
      expect(storable, contains(photo.id));
      expect(storable, isNot(contains(video.id)));
    });

    test('details are refused for a hidden asset too, so a decision already made stops being fetched', () async {
      final hidden = await ctx.newRemoteAsset(visibility: AssetVisibility.hidden, type: AssetType.video);
      final visible = await ctx.newRemoteAsset(visibility: AssetVisibility.timeline);

      // `detailsFor` is what the walk asks per page; an id it will not resolve is counted as unavailable rather than
      // queued (FORK.md §3.3).
      final details = await sut.detailsFor([hidden.id, visible.id]);

      expect(details.keys, [visible.id]);
    });
  });

  group('a Live Photo is one item', () {
    test('the photo carries the id of its motion part, so its file can be fetched under the photo', () async {
      final video = await ctx.newRemoteAsset(visibility: AssetVisibility.hidden, type: AssetType.video);
      final photo = await ctx.newRemoteAsset(type: AssetType.image, livePhotoVideoId: video.id);

      final details = await sut.detailsFor([photo.id]);

      expect(details[photo.id]!.motionVideoId, video.id);
      expect(details[photo.id]!.isImage, isTrue);
    });

    test('an ordinary photo has none', () async {
      final photo = await ctx.newRemoteAsset(type: AssetType.image);

      expect((await sut.detailsFor([photo.id]))[photo.id]!.motionVideoId, isNull);
    });

    test('candidates carry it too, since the derivation records it on the row', () async {
      final video = await ctx.newRemoteAsset(visibility: AssetVisibility.hidden, type: AssetType.video);
      final photo = await ctx.newRemoteAsset(type: AssetType.image, livePhotoVideoId: video.id);

      final candidates = await sut.allAssets(limit: 100);

      expect(candidates.singleWhere((c) => c.id == photo.id).motionVideoId, video.id);
    });

    test('hiddenIds names the halves a stale decision was made about', () async {
      final video = await ctx.newRemoteAsset(visibility: AssetVisibility.hidden, type: AssetType.video);
      final photo = await ctx.newRemoteAsset(type: AssetType.image, livePhotoVideoId: video.id);
      final trashed = await ctx.newRemoteAsset(deletedAt: DateTime.utc(2026, 8, 20));

      // The trashed one must *not* be named: the trash is undoable, so its decision is blocked rather than stale.
      expect(await sut.hiddenIds([video.id, photo.id, trashed.id]), {video.id});
    });
  });

  group('an album the selection names but upstream lost', () {
    test('existingAlbumIds keeps the ones that are still there and names nothing else', () async {
      final album = await ctx.newRemoteAlbum();

      final alive = await sut.existingAlbumIds([album.id, 'deleted-album-id']);

      expect(alive, {album.id});
    });

    test('an empty album is still alive — it just has no members', () async {
      // The distinction the fix turns on: `albumAssetCounts` reads the link table, so an empty album is missing from it
      // too. Forgetting one of those would silently discard a selection the user made.
      final empty = await ctx.newRemoteAlbum();

      expect(await sut.albumAssetCounts(), isNot(contains(empty.id)));
      expect(await sut.existingAlbumIds([empty.id]), {empty.id});
    });

    test("a deleted album's photos are only reachable from the library, not from the album", () async {
      // What made deleting an excluded album a no-op: the derivation walks the album, and the album is gone.
      final album = await ctx.newRemoteAlbum();
      final asset = await ctx.newRemoteAsset();
      await ctx.newRemoteAlbumAsset(albumId: album.id, assetId: asset.id);
      await (ctx.db.delete(ctx.db.remoteAlbumEntity)..where((row) => row.id.equals(album.id))).go();

      expect(await sut.assetsInAlbums([album.id], limit: 100), isEmpty);
      expect((await sut.allAssets(limit: 100)).map((c) => c.id), contains(asset.id));
    });
  });

  group('what the phone already holds', () {
    Future<void> localCopyOf(String checksum) => ctx.newLocalAsset(checksum: checksum);

    test('a photo with a camera-roll copy is reported as such', () async {
      final remote = await ctx.newRemoteAsset();
      await localCopyOf(remote.checksum);

      final details = await sut.detailsFor([remote.id]);

      expect(details[remote.id]!.hasLocalCopy, isTrue);
    });

    test('a photo with no matching checksum is not', () async {
      final remote = await ctx.newRemoteAsset();
      await ctx.newLocalAsset(checksum: 'something-else');

      expect((await sut.detailsFor([remote.id]))[remote.id]!.hasLocalCopy, isFalse);
    });

    test('a local copy is usable, so the mirror may skip the expensive files', () async {
      final remote = await ctx.newRemoteAsset();
      await localCopyOf(remote.checksum);

      expect((await sut.detailsFor([remote.id]))[remote.id]!.localCopyUsable, isTrue);
    });

    test('an edited photo renders from the server, so its local copy is not usable', () async {
      // `_shouldUseLocalAsset` ends in `&& !asset.isEdited`: the local file is the pre-edit picture.
      final remote = await ctx.newRemoteAsset(isEdited: true);
      await localCopyOf(remote.checksum);

      final asset = (await sut.detailsFor([remote.id]))[remote.id]!;

      expect(asset.hasLocalCopy, isTrue);
      expect(asset.localCopyUsable, isFalse);
    });

    test('Prefer remote images does not change it: one copy per device either way', () async {
      // That setting is about which copy to decode while online, not about whether the phone has the photo.
      final remote = await ctx.newRemoteAsset();
      await localCopyOf(remote.checksum);

      expect((await sut.detailsFor([remote.id]))[remote.id]!.localCopyUsable, isTrue);
    });
  });

  group('the fingerprint', () {
    test('moves when a local copy appears, which nothing else here can see', () async {
      final remote = await ctx.newRemoteAsset();
      final before = await sut.signature();

      await ctx.newLocalAsset(checksum: remote.checksum);
      final after = await sut.signature();

      // Deleting local originals is the whole point of upstream's Free Up Space; if the fingerprint cannot see it,
      // `check` decides nothing happened and those photos are never fetched.
      expect(after, isNot(before));
      expect(after.assetCount, before.assetCount);
      expect(after.localCount, before.localCount + 1);
    });
  });
}
