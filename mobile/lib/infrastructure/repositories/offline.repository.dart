/// immich-sync fork — the upstream-database side of offline storage. Everything here reads; the fork's own decisions
/// live in `offline_flags.repository.dart`.
library;

import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

/// An asset as far as offline storage is concerned: enough to name every file it implies, read fresh from upstream at
/// the point of use.
class OfflineAsset {
  const OfflineAsset({
    required this.id,
    required this.thumbHash,
    required this.isImage,
    required this.isEdited,
    required this.createdAt,
    this.motionVideoId,
    this.hasLocalCopy = false,
  });

  /// Whether this phone already holds the photo itself, which is the only reason the mirror may skip its expensive
  /// files. An **edited** asset is excluded: the server's rendition is the picture now, and the local file is the
  /// pre-edit one, so it is no substitute.
  ///
  /// Deliberately *not* conditioned on upstream's *Prefer remote images*: that setting is about which copy to decode
  /// while online, not about whether the phone has the photo, and one copy per device is the rule here. The cost is that
  /// with the setting on and no network, the viewer falls back to the mirrored preview rather than showing full quality
  /// from the camera roll — an upstream gap, since the local file is right there.
  bool get localCopyUsable => hasLocalCopy && !isEdited;

  final String id;
  final String thumbHash;
  final bool isImage;

  /// The video half of a Live Photo, when there is one. It is a hidden asset of its own on the server — never stored in
  /// its own right, since upstream generates no thumbnail for a hidden asset — but its playable file belongs to *this*
  /// item, and the viewer asks for it under that id (`video_viewer.widget.dart`).
  final String? motionVideoId;

  /// Whether the camera roll holds this asset, matched by checksum as upstream's merged view does.
  final bool hasLocalCopy;

  /// Whether the server holds an edited version, which is what makes `/original` a moving target — see
  /// `offlineOriginalUrl`.
  final bool isEdited;

  /// Capture date, which is the order the reconciler works in.
  final DateTime createdAt;
}

/// An asset that has just appeared, with the albums that decide its fate.
class OfflineCandidate {
  const OfflineCandidate({
    required this.id,
    required this.isImage,
    required this.createdAt,
    required this.updatedAt,
    required this.albumIds,
    this.motionVideoId,
  });

  final String id;
  final bool isImage;

  /// See [OfflineAsset.motionVideoId].
  final String? motionVideoId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> albumIds;
}

class OfflineRepository {
  const OfflineRepository(this._db);

  final Drift _db;

  /// Assets that can be stored at all.
  ///
  /// **Locked-folder** assets are never included: storing them would leave bytes readable outside the PIN gate.
  ///
  /// **Hidden** ones are the video half of a Live Photo, which upstream hides so the pair does not appear twice, and it
  /// excludes them from every query of its own (`asset-job.repository.ts`, `download.repository.ts`). The mirror has to
  /// as well, and not only for tidiness: thumbnail generation is *skipped* for a hidden asset
  /// (`media.service.ts`, `visibility === Hidden`), so it has no thumbnail or preview to serve and never will —
  /// wanting one is a 404 on every pass, for good.
  Expression<bool> _storable($RemoteAssetEntityTable row) =>
      row.deletedAt.isNull() &
      row.visibility.equalsValue(AssetVisibility.locked).not() &
      row.visibility.equalsValue(AssetVisibility.hidden).not();

  /// Everything storable, newest first, one page at a time.
  Future<List<OfflineCandidate>> allAssets({DateTime? afterCreatedAt, String? afterId, required int limit}) async {
    final assets = _db.remoteAssetEntity;
    final query = assets.select()
      ..where(
        (row) => afterCreatedAt == null
            ? _storable(row)
            : _storable(row) &
                  (row.createdAt.isSmallerThanValue(afterCreatedAt) |
                      (row.createdAt.equals(afterCreatedAt) & row.id.isSmallerThanValue(afterId!))),
      )
      ..orderBy([(row) => OrderingTerm.desc(row.createdAt), (row) => OrderingTerm.desc(row.id)])
      ..limit(limit);

    return (await query.get())
        .map(
          (row) => OfflineCandidate(
            id: row.id,
            isImage: row.type == AssetType.image,
            motionVideoId: row.livePhotoVideoId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            albumIds: const [],
          ),
        )
        .toList();
  }

  /// Everything storable in an album, for its own progress line.
  Future<List<OfflineCandidate>> assetsInAlbum(String albumId) async {
    final assets = _db.remoteAssetEntity;
    final link = _db.remoteAlbumAssetEntity;
    final members = link.selectOnly()
      ..addColumns([link.assetId])
      ..where(link.albumId.equals(albumId));

    final query = assets.select()
      ..where((row) => _storable(row) & row.id.isInQuery(members))
      ..orderBy([(row) => OrderingTerm.desc(row.createdAt)]);

    return (await query.get())
        .map(
          (row) => OfflineCandidate(
            id: row.id,
            isImage: row.type == AssetType.image,
            motionVideoId: row.livePhotoVideoId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            albumIds: [albumId],
          ),
        )
        .toList();
  }

  /// Storable assets in any of [albumIds], paged like [allAssets].
  Future<List<OfflineCandidate>> assetsInAlbums(
    Iterable<String> albumIds, {
    DateTime? afterCreatedAt,
    String? afterId,
    required int limit,
  }) async {
    final ids = albumIds.toList();
    if (ids.isEmpty) {
      return const [];
    }

    final assets = _db.remoteAssetEntity;
    final link = _db.remoteAlbumAssetEntity;
    final members = link.selectOnly()
      ..addColumns([link.assetId])
      ..where(link.albumId.isIn(ids));

    final query = assets.select()
      ..where((row) {
        final scoped = _storable(row) & row.id.isInQuery(members);
        return afterCreatedAt == null
            ? scoped
            : scoped &
                  (row.createdAt.isSmallerThanValue(afterCreatedAt) |
                      (row.createdAt.equals(afterCreatedAt) & row.id.isSmallerThanValue(afterId!)));
      })
      ..orderBy([(row) => OrderingTerm.desc(row.createdAt), (row) => OrderingTerm.desc(row.id)])
      ..limit(limit);

    return (await query.get())
        .map(
          (row) => OfflineCandidate(
            id: row.id,
            isImage: row.type == AssetType.image,
            motionVideoId: row.livePhotoVideoId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            albumIds: const [],
          ),
        )
        .toList();
  }

  /// Fires whenever the camera roll's contents change, which nothing else tells the mirror about.
  ///
  /// `onRemoteChanged` covers the server; this covers the device. Deleting a local original — by *remove from device*, by
  /// Free Up Space, or in Photos — is a write to `local_asset_entity` and no kind of remote change, so without this the
  /// mirror learns that it now owes those photos a full copy only at the next cold start (§3.2).
  ///
  /// The notification, not a query. Drift re-runs a watched statement on every write to the tables it reads, and the
  /// obvious spelling of this — watching `COUNT(*)` and taking it `distinct` — pays a full scan of the camera roll per
  /// write to decide whether to emit. `distinct` filters the *emissions*; it cannot stop the query running. During the
  /// full local sync at launch that is one scan per batch, on the connection the timeline is waiting on for its own
  /// first read, and it is the answer that gets thrown away most of the time: hashing writes a checksum onto every
  /// local asset it processes without changing the count at all.
  ///
  /// Table updates cost nothing to observe and say exactly as much — that something wrote — which is all the caller
  /// needs before asking a pass to look. It debounces them (`offline.provider.dart`), so a sync that writes for a
  /// minute wakes one pass at the end rather than one throughout.
  Stream<void> watchLocalAssets() => _db.tableUpdates(TableUpdateQuery.onTable(_db.localAssetEntity));

  /// Fires whenever upstream's own tables are written — the server side of the same question.
  ///
  /// The three that decide what the mirror keeps: the assets, the albums, and which asset is in which album. Watching
  /// writes rather than fingerprinting values is what lets the mirror notice an asset changing **in place** — an edit
  /// applied, an edit reverted, a trashing — none of which moves a row count, and none of which touches `updated_at`,
  /// which upstream fills from `fileModifiedAt` and is therefore a property of the photograph rather than a clock.
  Stream<void> watchRemote() => _db.tableUpdates(
    TableUpdateQuery.onAllTables([_db.remoteAssetEntity, _db.remoteAlbumEntity, _db.remoteAlbumAssetEntity]),
  );

  /// Thumbhash and type for assets the fork wants.
  ///
  /// Chunked: a pass hands over a page at a time, but "Save offline" hands over whatever the user selected, and Select
  /// all is the whole timeline.
  Future<Map<String, OfflineAsset>> detailsFor(List<String> ids) async {
    final assets = _db.remoteAssetEntity;
    final details = <String, OfflineAsset>{};

    for (final chunk in _chunked(ids)) {
      final rows = await (assets.select()..where((row) => _storable(row) & row.id.isIn(chunk))).get();
      // Two plain queries rather than one correlated sub-select, whose failure mode is silent: it reads as correct,
      // returns nothing, and the only symptom is photos the phone already holds being mirrored in full anyway. Whether
      // the camera roll has a photo is decided the same way upstream's merged view decides it (`merged_asset.drift`) —
      // a checksum match — and this asks that question in a form that is obvious at a glance.
      final localChecksums = await _checksumsOnDevice({for (final row in rows) row.checksum});

      for (final row in rows) {
        details[row.id] = OfflineAsset(
          id: row.id,
          thumbHash: row.thumbHash ?? '',
          isImage: row.type == AssetType.image,
          motionVideoId: row.livePhotoVideoId,
          hasLocalCopy: localChecksums.contains(row.checksum),
          isEdited: row.isEdited,
          createdAt: row.createdAt,
        );
      }
    }
    return details;
  }

  /// Which of [checksums] the camera roll holds.
  Future<Set<String>> _checksumsOnDevice(Set<String> checksums) async {
    if (checksums.isEmpty) {
      return const {};
    }

    final locals = _db.localAssetEntity;
    final query = locals.selectOnly()
      ..addColumns([locals.checksum])
      ..where(locals.checksum.isIn(checksums.toList()));

    return {for (final row in await query.get()) ?row.read(locals.checksum)};
  }

  /// Which of [ids] upstream still has a row for at all.
  ///
  /// Chunked like [albumsOf]: the callers ask about every decision a pass could not resolve, which after a sync reset is
  /// the whole library, and one `IN` list that long is a "too many SQL variables" error that takes the pass down with it.
  Future<Set<String>> existingIds(List<String> ids) async {
    final assets = _db.remoteAssetEntity;
    final found = <String>{};

    for (final chunk in _chunked(ids)) {
      final query = assets.selectOnly()
        ..addColumns([assets.id])
        ..where(assets.id.isIn(chunk));
      for (final row in await query.get()) {
        final id = row.read<String>(assets.id);
        if (id != null) {
          found.add(id);
        }
      }
    }
    return found;
  }

  /// Which of [ids] upstream keeps hidden — the video half of a Live Photo.
  ///
  /// Unlike the trash and the locked folder, this is not a state the user put the item in and can take it out of: it is
  /// how the server stores one half of a pair, and the mirror now fetches that half as a file of the *photo* instead
  /// (§3.2). A decision about one is therefore stale rather than blocked, and the pass forgets it — otherwise rows
  /// written before that changed sit in the "cannot be downloaded" count for ever.
  Future<Set<String>> hiddenIds(List<String> ids) => _idsWithVisibility(ids, AssetVisibility.hidden);

  /// Which of [ids] are in the locked folder, whose bytes must not sit outside the PIN gate.
  Future<Set<String>> lockedIds(List<String> ids) => _idsWithVisibility(ids, AssetVisibility.locked);

  Future<Set<String>> _idsWithVisibility(List<String> ids, AssetVisibility visibility) async {
    final assets = _db.remoteAssetEntity;
    final found = <String>{};

    // Chunked for the same reason as [existingIds]: the same unresolved list reaches both.
    for (final chunk in _chunked(ids)) {
      final query = assets.selectOnly()
        ..addColumns([assets.id])
        ..where(assets.id.isIn(chunk) & assets.visibility.equalsValue(visibility));
      for (final row in await query.get()) {
        final id = row.read<String>(assets.id);
        if (id != null) {
          found.add(id);
        }
      }
    }
    return found;
  }

  /// How many assets upstream has, at all.
  ///
  /// A guard rather than a fingerprint: a database mid-repopulation after a fresh install, a sync reset or a sign-out
  /// looks exactly like a library emptied on the server, and neither the reconciler nor the integrity pass may act on
  /// it. What *changed* is no longer asked of the data at all — a write says so as it happens
  /// (`offline_sync.service.dart`).
  Future<int> assetCount() async {
    final assets = _db.remoteAssetEntity;
    final count = assets.id.count();
    return (await (assets.selectOnly()..addColumns([count])).getSingle()).read(count) ?? 0;
  }

  /// Number of assets in each album, for the selection UI.
  Future<Map<String, int>> albumAssetCounts() async {
    final link = _db.remoteAlbumAssetEntity;
    final count = link.assetId.count();
    final query = link.selectOnly()
      ..addColumns([link.albumId, count])
      ..groupBy([link.albumId]);

    return {for (final row in await query.get()) row.read(link.albumId)!: row.read(count) ?? 0};
  }

  /// How many of each album's storable assets are also in one of [excludedAlbumIds].
  ///
  /// An exclusion beats everything (`OfflinePolicy.resolve`), so an album overlapping one loses those items without
  /// saying anything: its own row counts fewer than the album holds and nothing accounts for the difference. This is
  /// what lets it be named, the same way an album overruled *upwards* names its uplift.
  ///
  /// One grouped query for every album rather than a question per row, because the screen lists every album the server
  /// has. Albums in [excludedAlbumIds] are left out — an excluded album loses nothing to being excluded.
  Future<Map<String, int>> excludedOverlapCounts(Iterable<String> excludedAlbumIds) async {
    final ids = excludedAlbumIds.toList();
    if (ids.isEmpty) {
      return const {};
    }

    final assets = _db.remoteAssetEntity;
    final link = _db.remoteAlbumAssetEntity;
    // Aliased, because the subquery walks the same table as the query around it. Unaliased, both sides would emit
    // `remote_album_asset_entity.album_id` and the reader would be left working out which scope each one binds to.
    final excludedLink = _db.alias(_db.remoteAlbumAssetEntity, 'excluded_link');
    final excludedAssets = excludedLink.selectOnly()
      ..addColumns([excludedLink.assetId])
      ..where(excludedLink.albumId.isIn(ids));

    final count = link.assetId.count();
    // Joined to the asset table for [_storable], so the figure counts the same population an album's progress line
    // does: a trashed photo is absent from one and would otherwise be present in the other.
    final query = link.selectOnly()
      ..addColumns([link.albumId, count])
      ..join([innerJoin(assets, assets.id.equalsExp(link.assetId), useColumns: false)])
      ..where(link.albumId.isIn(ids).not() & link.assetId.isInQuery(excludedAssets) & _storable(assets))
      ..groupBy([link.albumId]);

    return {for (final row in await query.get()) row.read(link.albumId)!: row.read(count) ?? 0};
  }

  /// Which of [albumIds] upstream still has, so a selection can drop the ones it does not.
  ///
  /// Album *existence*, not membership: an empty album has no rows in the link table and so is missing from
  /// [albumAssetCounts] too, and forgetting one of those would silently discard a selection the user made.
  Future<Set<String>> existingAlbumIds(Iterable<String> albumIds) async {
    final ids = albumIds.toList();
    if (ids.isEmpty) {
      return const {};
    }

    final albums = _db.remoteAlbumEntity;
    final query = albums.selectOnly()
      ..addColumns([albums.id])
      ..where(albums.id.isIn(ids));

    return {for (final row in await query.get()) ?row.read<String>(albums.id)};
  }

  /// Album memberships for the given assets.
  Future<Map<String, List<String>>> albumsOf(List<String> assetIds) async {
    final link = _db.remoteAlbumAssetEntity;
    final result = <String, List<String>>{};

    for (final chunk in _chunked(assetIds)) {
      final query = link.selectOnly()
        ..addColumns([link.assetId, link.albumId])
        ..where(link.assetId.isIn(chunk));

      for (final row in await query.get()) {
        // Explicit type arguments: with no downward context, `read` infers
        // `Object` and the map index stops compiling.
        final assetId = row.read<String>(link.assetId);
        final albumId = row.read<String>(link.albumId);
        if (assetId != null && albumId != null) {
          (result[assetId] ??= []).add(albumId);
        }
      }
    }
    return result;
  }

  /// Ids in batches an `IN` list can carry. Every query here takes a list a caller assembled — a page, an album, or a
  /// multi-select — and none of them is bounded by anything but the library, so they all go through this.
  Iterable<List<String>> _chunked(List<String> ids) sync* {
    for (var start = 0; start < ids.length; start += _idsPerQuery) {
      final end = start + _idsPerQuery;
      yield ids.sublist(start, end > ids.length ? ids.length : end);
    }
  }
}

/// Well inside SQLite's variable limit, which is 999 by default.
const _idsPerQuery = 500;
