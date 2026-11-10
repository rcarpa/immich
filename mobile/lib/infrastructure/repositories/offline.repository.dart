/// immich-sync fork: what offline storage reads from upstream's tables. The fork's own rows are in
/// `offline_flags.repository.dart`.
library;

import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';

class OfflineAsset {
  const OfflineAsset({
    required this.id,
    required this.thumbHash,
    required this.isImage,
    required this.isEdited,
    required this.createdAt,
    this.motionVideoId,
    this.hasLocalCopy = false,
    this.originalChecksum,
  });

  /// Whether this phone holds the photo itself, the only reason the mirror skips its full-size files. Never for an
  /// edited asset, whose local file is the pre-edit one. Independent of *Prefer remote images*.
  bool get localCopyUsable => hasLocalCopy && !isEdited;

  final String id;
  final String thumbHash;
  final bool isImage;

  /// The video half of a Live Photo, if any. Stored as a file of this item, under the id the viewer asks for.
  final String? motionVideoId;

  /// Whether the camera roll holds this asset, matched by checksum as upstream's merged view does.
  final bool hasLocalCopy;

  /// Whether the server holds an edited version, which changes what `/original` returns (see `offlineOriginalUrl`).
  final bool isEdited;

  final DateTime createdAt;

  /// The server's base64 SHA-1 of the bytes `/original` returns, which downloads are verified against. Null when it
  /// would not match them: an edited asset is served from its edit, and an external library's checksum hashes the
  /// file's path rather than its content (`sha1-path` on the server).
  final String? originalChecksum;
}

/// Assets that may be stored, over upstream's asset table as [a]: not trashed, not in the locked folder, which must stay
/// behind the PIN, and not hidden (a Live Photo's video half), for which the server generates no thumbnails. The one
/// definition, shared by these queries and the derive's SQL.
String offlineStorableSql(String a) =>
    '$a.deleted_at IS NULL '
    'AND $a.visibility <> ${AssetVisibility.locked.index} '
    'AND $a.visibility <> ${AssetVisibility.hidden.index}';

class OfflineRepository {
  const OfflineRepository(this._db);

  final Drift _db;

  Expression<bool> _storable($RemoteAssetEntityTable row) =>
      CustomExpression<bool>('(${offlineStorableSql('"${row.aliasedName}"')})');

  Future<List<String>> assetsInAlbum(String albumId) async {
    final assets = _db.remoteAssetEntity;
    final link = _db.remoteAlbumAssetEntity;
    final members = link.selectOnly()
      ..addColumns([link.assetId])
      ..where(link.albumId.equals(albumId));

    final query = assets.selectOnly()
      ..addColumns([assets.id])
      ..where(_storable(assets) & assets.id.isInQuery(members))
      ..orderBy([OrderingTerm.desc(assets.createdAt)]);
    return query.map((row) => row.read(assets.id)!).get();
  }

  /// Fires on every write to the camera-roll table. Removing a local original makes the mirror owe a full copy. Table
  /// updates rather than a watched query, which would re-run a full scan on every write.
  Stream<void> watchLocalAssets() => _db.tableUpdates(TableUpdateQuery.onTable(_db.localAssetEntity));

  /// Fires on every write to the upstream tables that decide what the mirror keeps.
  Stream<void> watchRemote() => _db.tableUpdates(
    TableUpdateQuery.onAllTables([_db.remoteAssetEntity, _db.remoteAlbumEntity, _db.remoteAlbumAssetEntity]),
  );

  /// Thumbhash and type for assets the fork wants. Chunked: *Save offline* on Select all is the whole timeline.
  Future<Map<String, OfflineAsset>> detailsFor(List<String> ids) async {
    final assets = _db.remoteAssetEntity;
    final details = <String, OfflineAsset>{};

    for (final chunk in _chunked(ids)) {
      final rows = await (assets.select()..where((row) => _storable(row) & row.id.isIn(chunk))).get();
      // Two plain queries; whether the camera roll has a photo is a checksum match, as in `merged_asset.drift`.
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
          originalChecksum: row.libraryId == null && !row.isEdited && row.checksum.isNotEmpty ? row.checksum : null,
        );
      }
    }
    return details;
  }

  /// The sizes upstream synced for [ids]' originals, and for a Live Photo's motion part. Asked only for items still
  /// missing a full-size file, so a complete mirror asks nothing.
  Future<Map<String, OfflineSizes>> sizesOf(List<String> ids) async {
    final sizes = <String, OfflineSizes>{};
    for (final chunk in _chunked(ids)) {
      final rows = await _db
          .customSelect(
            'SELECT a.id AS id, a.is_edited AS is_edited, e.file_size AS original, me.file_size AS motion '
            'FROM remote_asset_entity a '
            'LEFT JOIN remote_exif_entity e ON e.asset_id = a.id '
            'LEFT JOIN remote_exif_entity me ON me.asset_id = a.live_photo_video_id '
            'WHERE a.id IN (${List.filled(chunk.length, '?').join(', ')})',
            variables: [for (final id in chunk) Variable<String>(id)],
          )
          .get();
      for (final row in rows) {
        sizes[row.read<String>('id')] = (
          original: row.readNullable<int>('original') ?? 0,
          motion: row.readNullable<int>('motion') ?? 0,
          isEdited: row.read<bool>('is_edited'),
        );
      }
    }
    return sizes;
  }

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

  /// Which of [ids] upstream still has a row for. Chunked, since after a sync reset this can be the whole library.
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

  /// Which of [ids] upstream keeps hidden: the video half of a Live Photo, now fetched as part of its photo, so a
  /// decision about one alone is stale.
  Future<Set<String>> hiddenIds(List<String> ids) => _idsWithVisibility(ids, AssetVisibility.hidden);

  /// Which of [ids] are in the locked folder, whose bytes must not sit outside the PIN gate.
  Future<Set<String>> lockedIds(List<String> ids) => _idsWithVisibility(ids, AssetVisibility.locked);

  Future<Set<String>> _idsWithVisibility(List<String> ids, AssetVisibility visibility) async {
    final assets = _db.remoteAssetEntity;
    final found = <String>{};

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

  /// How many assets upstream has. A guard: an empty database mid-repopulation looks like a library emptied on the
  /// server.
  Future<int> assetCount() async {
    final assets = _db.remoteAssetEntity;
    final count = assets.id.count();
    return (await (assets.selectOnly()..addColumns([count])).getSingle()).read(count) ?? 0;
  }

  Future<Map<String, int>> albumAssetCounts() async {
    final link = _db.remoteAlbumAssetEntity;
    final count = link.assetId.count();
    final query = link.selectOnly()
      ..addColumns([link.albumId, count])
      ..groupBy([link.albumId]);

    return {for (final row in await query.get()) row.read(link.albumId)!: row.read(count) ?? 0};
  }

  /// How many of each album's storable assets are also in one of [excludedAlbumIds], so the screen can explain why an
  /// album keeps fewer items than it holds. Excluded albums themselves are left out.
  Future<Map<String, int>> excludedOverlapCounts(Iterable<String> excludedAlbumIds) async {
    final ids = excludedAlbumIds.toList();
    if (ids.isEmpty) {
      return const {};
    }

    final assets = _db.remoteAssetEntity;
    final link = _db.remoteAlbumAssetEntity;
    // Aliased, since the subquery reads the same table.
    final excludedLink = _db.alias(_db.remoteAlbumAssetEntity, 'excluded_link');
    final excludedAssets = excludedLink.selectOnly()
      ..addColumns([excludedLink.assetId])
      ..where(excludedLink.albumId.isIn(ids));

    final count = link.assetId.count();
    // Joined for [_storable], so this counts what an album's progress line counts.
    final query = link.selectOnly()
      ..addColumns([link.albumId, count])
      ..join([innerJoin(assets, assets.id.equalsExp(link.assetId), useColumns: false)])
      ..where(link.albumId.isIn(ids).not() & link.assetId.isInQuery(excludedAssets) & _storable(assets))
      ..groupBy([link.albumId]);

    return {for (final row in await query.get()) row.read(link.albumId)!: row.read(count) ?? 0};
  }

  /// Which of [albumIds] upstream still has. Asks for the album, not its links, so an empty album is not dropped.
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

  Future<Map<String, List<String>>> albumsOf(List<String> assetIds) async {
    final link = _db.remoteAlbumAssetEntity;
    final result = <String, List<String>>{};

    for (final chunk in _chunked(assetIds)) {
      final query = link.selectOnly()
        ..addColumns([link.assetId, link.albumId])
        ..where(link.assetId.isIn(chunk));

      for (final row in await query.get()) {
        // Explicit type arguments, or `read` infers `Object`.
        final assetId = row.read<String>(link.assetId);
        final albumId = row.read<String>(link.albumId);
        if (assetId != null && albumId != null) {
          (result[assetId] ??= []).add(albumId);
        }
      }
    }
    return result;
  }

  Iterable<List<String>> _chunked(List<String> ids) sync* {
    for (var start = 0; start < ids.length; start += _idsPerQuery) {
      final end = start + _idsPerQuery;
      yield ids.sublist(start, end > ids.length ? ids.length : end);
    }
  }
}

const _idsPerQuery = 500;
