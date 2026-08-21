/// immich-sync fork — the upstream-database side of offline storage. Everything here reads; the fork's own decisions
/// live in `offline_flags.repository.dart`.
library;

import 'package:drift/drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/entities/remote_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

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

/// A cheap fingerprint of everything upstream that could change what is stored.
class OfflineSignature {
  const OfflineSignature({
    required this.assetCount,
    required this.latestUpdate,
    required this.albumLinkCount,
    required this.localCount,
  });

  final int assetCount;

  /// Catches edits and additions. A pure deletion moves [assetCount] instead.
  final DateTime? latestUpdate;

  /// Catches an asset joining or leaving an album, which changes what policy would decide without touching any asset
  /// row.
  final int albumLinkCount;

  /// Catches the camera roll changing, which nothing else here can see: every other component is about the *server*, and
  /// the mirror now skips files the phone already holds. Without this, deleting local originals — the whole point of
  /// upstream's Free Up Space — moves nothing, `check` concludes nothing happened, and those photos are never fetched.
  final int localCount;

  @override
  bool operator ==(Object other) =>
      other is OfflineSignature &&
      other.assetCount == assetCount &&
      other.latestUpdate == latestUpdate &&
      other.albumLinkCount == albumLinkCount &&
      other.localCount == localCount;

  @override
  int get hashCode => Object.hash(assetCount, latestUpdate, albumLinkCount, localCount);
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

  /// Assets touched since [since], oldest change first, with their albums — what policy is applied to.
  Future<List<OfflineCandidate>> assetsChangedSince(DateTime? since, String? afterId, {required int limit}) async {
    final assets = _db.remoteAssetEntity;
    final query = assets.select()
      ..where(
        (row) => since == null
            ? _storable(row)
            : _storable(row) &
                  (row.updatedAt.isBiggerThanValue(since) |
                      (row.updatedAt.equals(since) & row.id.isBiggerThanValue(afterId ?? ''))),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.updatedAt), (row) => OrderingTerm.asc(row.id)])
      ..limit(limit);

    final rows = await query.get();
    if (rows.isEmpty) {
      return const [];
    }

    final albums = await albumsOf(rows.map((row) => row.id).toList());
    return rows
        .map(
          (row) => OfflineCandidate(
            id: row.id,
            isImage: row.type == AssetType.image,
            motionVideoId: row.livePhotoVideoId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            albumIds: albums[row.id] ?? const [],
          ),
        )
        .toList();
  }

  /// The newest storable assets by upstream's `updatedAt`, with the albums that decide their fate.
  ///
  /// The window a policy pass re-examines whatever its watermark says. `updatedAt` is the *server's* clock and upstream
  /// syncs by a cursor of its own, so rows do not arrive in `updatedAt` order: one that lands below the high-water mark
  /// is invisible to [assetsChangedSince] for ever, and the only symptom is a photo the mirror never keeps. This is
  /// bounded by [limit] rather than by the library, so paying it on every pass costs the same on a phone with a hundred
  /// photos and one with a hundred thousand.
  Future<List<OfflineCandidate>> recentlyChanged({required int limit}) async {
    final assets = _db.remoteAssetEntity;
    final query = assets.select()
      ..where(_storable)
      ..orderBy([(row) => OrderingTerm.desc(row.updatedAt), (row) => OrderingTerm.desc(row.id)])
      ..limit(limit);

    final rows = await query.get();
    if (rows.isEmpty) {
      return const [];
    }

    final albums = await albumsOf(rows.map((row) => row.id).toList());
    return rows
        .map(
          (row) => OfflineCandidate(
            id: row.id,
            isImage: row.type == AssetType.image,
            motionVideoId: row.livePhotoVideoId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            albumIds: albums[row.id] ?? const [],
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
  /// A count rather than the rows: drift re-runs the query when the table is written and not otherwise, so this cannot
  /// be woken by scrolling.
  ///
  /// `distinct` because "written" is not "changed": hashing writes a checksum onto every local asset it processes, so a
  /// backup run re-runs this query continuously with the same answer. Each of those would wake a pass, and a pass holds
  /// the lock a setting change needs.
  Stream<int> watchLocalAssetCount() {
    final locals = _db.localAssetEntity;
    final count = locals.id.count();
    return (locals.selectOnly()..addColumns([count])).map((row) => row.read(count) ?? 0).watchSingle().distinct();
  }

  /// The newest `updatedAt` among assets that can actually be stored.
  ///
  /// Distinct from `signature().latestUpdate`, which is the maximum over *every* row: the policy watermark is consumed
  /// by [assetsChangedSince], which filters to what is storable, so a watermark taken from the unfiltered maximum can
  /// sit above storable assets that were never decided — and trashing a photo bumps its `updatedAt`, as does the hidden
  /// motion half of every Live Photo.
  Future<DateTime?> latestStorableUpdate() async {
    final assets = _db.remoteAssetEntity;
    final latest = assets.updatedAt.max();
    final row = await (assets.selectOnly()
          ..addColumns([latest])
          ..where(_storable(assets)))
        .getSingle();
    return row.read(latest);
  }

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
  Future<Set<String>> hiddenIds(List<String> ids) async {
    final assets = _db.remoteAssetEntity;
    final found = <String>{};

    // Chunked for the same reason as [existingIds]: the same unresolved list reaches both.
    for (final chunk in _chunked(ids)) {
      final query = assets.selectOnly()
        ..addColumns([assets.id])
        ..where(assets.id.isIn(chunk) & assets.visibility.equalsValue(AssetVisibility.hidden));
      for (final row in await query.get()) {
        final id = row.read<String>(assets.id);
        if (id != null) {
          found.add(id);
        }
      }
    }
    return found;
  }

  /// The fingerprint described on [OfflineSignature].
  Future<OfflineSignature> signature() async {
    final assets = _db.remoteAssetEntity;
    final count = assets.id.count();
    final latest = assets.updatedAt.max();
    final assetRow = await (assets.selectOnly()..addColumns([count, latest])).getSingle();

    final link = _db.remoteAlbumAssetEntity;
    final linkCount = link.assetId.count();
    final linkRow = await (link.selectOnly()..addColumns([linkCount])).getSingle();

    final locals = _db.localAssetEntity;
    final localCount = locals.id.count();
    final localRow = await (locals.selectOnly()..addColumns([localCount])).getSingle();

    return OfflineSignature(
      assetCount: assetRow.read(count) ?? 0,
      latestUpdate: assetRow.read(latest),
      albumLinkCount: linkRow.read(linkCount) ?? 0,
      localCount: localRow.read(localCount) ?? 0,
    );
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

    return {
      for (final row in await query.get()) ?row.read<String>(albums.id),
    };
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
