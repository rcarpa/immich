/// immich-sync fork — which photos are wanted on this device (`wanted`), and which of their files are here (`held`).
/// Its own SQLite file rather than a drift table, because a fork-owned migration in upstream's schema would conflict on
/// nearly every rebase (FORK.md §3.2.1).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite_async/sqlite_async.dart';

/// Originals and playable files — the expensive, optional part of an asset, and what a preview may not be taken from
/// under.
final String _fullSizeVariants = '${OfflineVariant.original.index},${OfflineVariant.video.index}';

/// When a held file is maintained by nothing, over the aliases [h] and [w].
///
/// The playable file belongs to a video asset *or* to the still of a Live Photo, whose motion part is stored under the
/// photo's own id (§3.2). Without that second case the integrity pass reclaims a Live Photo's video the moment it
/// arrives, and "free up space" quotes it as unwanted.
///
/// **A full-size file is a spare whenever the camera roll holds the original** (`local_copy`), whatever rung the row
/// records. The mirror never fetches one for those items (§3.2), so no selection can be said to maintain it: the only
/// way it gets here is *Save offline*, which asks for a spare and says so. Reading the rung alone would file that copy
/// as library — promising a maintenance it does not get, and putting it out of reach of the removal that should take it,
/// because "kept by your settings" is locked until every spare above it is going.
String _unselectedOver(String h, String w) =>
    '$w.asset_id IS NULL '
    'OR $w.on_demand = 1 '
    'OR ($h.variant IN ($_fullSizeVariants) AND $w.local_copy = 1) '
    'OR ($h.variant = ${OfflineVariant.original.index} '
    '    AND NOT ($w.is_image = 1 AND $w.quality >= ${OfflineQuality.full.code})) '
    'OR ($h.variant = ${OfflineVariant.video.index} '
    '    AND NOT (($w.is_image = 0 OR $w.has_motion = 1) '
    '             AND $w.quality >= ${OfflineQuality.fullWithVideos.code}))';

/// The SQL each reclaim kind stands for.
extension _ReclaimSql on OfflineReclaimKind {
  /// The variants each covers, as SQL.
  String get variants => switch (this) {
    OfflineReclaimKind.videos => '${OfflineVariant.video.index}',
    OfflineReclaimKind.originals => '${OfflineVariant.original.index}',
    OfflineReclaimKind.previews => '${OfflineVariant.thumbnail.index},${OfflineVariant.preview.index}',
  };

}

/// One reclaim as a `WHERE` clause, so the figure a screen quotes and the files a deletion takes are the same set by
/// construction.
extension _ReclaimWhere on OfflineReclaim {
  /// The rows in one band, over the aliases [h] and [w].
  static String band(OfflineReclaimBand band, String h, String w) => switch (band) {
    OfflineReclaimBand.spares => '(${_unselectedOver(h, w)})',
    OfflineReclaimBand.maintained => 'NOT (${_unselectedOver(h, w)})',
  };

  /// Every cell of the choice, over the aliases [h] and [w]: one band-and-kind pair per `OR`.
  String cellsOver(String h, String w) {
    if (cells.isEmpty) {
      return '0';
    }
    return cells
        .map((cell) => '(${band(cell.$1, h, w)} AND $h.variant IN (${cell.$2.variants}))')
        .join(' OR ');
  }

  /// The whole predicate: the cells that were ticked, minus the previews that would be left holding nothing up.
  String get sql {
    if (cells.isEmpty) {
      return '0';
    }
    final survivor =
        'SELECT 1 FROM held g LEFT JOIN wanted wg ON wg.asset_id = g.asset_id AND wg.quality > 0 '
        'WHERE g.asset_id = h.asset_id AND g.variant IN ($_fullSizeVariants) '
        'AND NOT (${cellsOver('g', 'wg')})';
    return '(${cellsOver('h', 'w')}) '
        'AND (h.variant IN ($_fullSizeVariants) OR NOT EXISTS ($survivor))';
  }
}

class OfflineFlagsRepository {
  OfflineFlagsRepository._(this._db, this.path);

  final SqliteDatabase _db;
  final String path;

  static OfflineFlagsRepository? _opened;

  /// Available once [open] has run, which bootstrap does before any provider is read. A getter rather than a nullable
  /// field so a mistake in that ordering fails loudly instead of silently deciding nothing is wanted.
  static OfflineFlagsRepository get instance {
    final opened = _opened;
    if (opened == null) {
      throw StateError('OfflineFlagsRepository.open() must run during bootstrap');
    }
    return opened;
  }

  static Future<OfflineFlagsRepository> open() async {
    final existing = _opened;
    if (existing != null) {
      return existing;
    }

    final support = await getApplicationSupportDirectory();
    final instance = await openAt(p.join(support.path, 'mirrich_offline.sqlite'));
    _opened = instance;
    return instance;
  }

  /// Opens the schema at an arbitrary path, without becoming [instance].
  ///
  /// For the tests that exercise the reclaim bands: the predicate deciding which held files a removal may take is SQL
  /// and has no Dart twin to test instead, which is the point — one expression is what keeps the figure a screen quotes
  /// and the files a deletion takes the same set. So the tests run it against a real database.
  @visibleForTesting
  static Future<OfflineFlagsRepository> openAt(String file) async {
    final db = SqliteDatabase(path: file);

    await db.writeTransaction((tx) async {
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS wanted (
          asset_id   TEXT PRIMARY KEY,
          quality    INTEGER NOT NULL,
          is_image   INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          on_demand  INTEGER NOT NULL DEFAULT 0,
          touched_at INTEGER NOT NULL DEFAULT 0,
          has_motion INTEGER NOT NULL DEFAULT 0,
          local_copy INTEGER NOT NULL DEFAULT 0
        )
      ''');
      // Columns that reached the CREATE above later than the rest, so a database written by an older build has the table
      // without them — and SQLite has no ADD COLUMN IF NOT EXISTS to lean on. Added here rather than by versioning the
      // schema: every one of them can take its default on an existing row, because the next pass re-derives it. Keep
      // this list even once no such database plausibly exists; it costs one PRAGMA per launch and its absence costs the
      // store.
      final columns = {for (final column in await tx.getAll('PRAGMA table_info(wanted)')) column['name'] as String};
      for (final added in const [
        ('has_motion', 'INTEGER NOT NULL DEFAULT 0'),
        ('local_copy', 'INTEGER NOT NULL DEFAULT 0'),
      ]) {
        if (!columns.contains(added.$1)) {
          await tx.execute('ALTER TABLE wanted ADD COLUMN ${added.$1} ${added.$2}');
        }
      }
      // The order the reconciler *pages* in: most recently asked for first, then newest photo. The rank that decides
      // what is fetched first is applied in Dart (FORK.md §3.3), since it depends on the variants a row implies. The
      // tie-break column lets paging be a cursor rather than an OFFSET.
      await tx.execute(
        'CREATE INDEX IF NOT EXISTS idx_wanted_queue ON wanted (touched_at DESC, created_at DESC, asset_id DESC)',
      );
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS held (
          name     TEXT PRIMARY KEY,
          asset_id TEXT NOT NULL,
          variant  INTEGER NOT NULL,
          token    INTEGER NOT NULL,
          size     INTEGER NOT NULL
        )
      ''');
      await tx.execute('CREATE INDEX IF NOT EXISTS idx_held_asset ON held (asset_id)');
      // Assets asked for by hand and not yet complete — the only thing that outranks a standing selection (FORK.md
      // §3.3). Its own table rather than a column on `wanted`, because `on_demand` there answers a different question:
      // whether the copies are reclaimable as a cache, which is false whenever a selection also covers the item — which
      // is exactly when an errand still needs to jump the queue. A row lives from the tap until its files are here, so
      // the table is the size of what you tapped, not of the library.
      await tx.execute('CREATE TABLE IF NOT EXISTS errands (asset_id TEXT PRIMARY KEY)');
      await tx.execute('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      // Files the server will not give us — a photo deleted mid-pass, or one it cannot generate a preview for.
      // Attempted a few times, then left alone rather than retried on every pass forever.
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS failures (
          name     TEXT PRIMARY KEY,
          attempts INTEGER NOT NULL DEFAULT 1
        )
      ''');
    });

    return OfflineFlagsRepository._(db, file);
  }

  /// Bumped on every write, so a caller can notice that something it derived from these rows is out of date.
  int revision = 0;

  // --------------------------------------------------------------------------- Reading

  /// Assets wanted offline: most recently asked for first, newest photo first within one change.
  Future<List<OfflineWant>> page({OfflineWantCursor? after, required int limit}) async {
    const columns = 'SELECT asset_id, quality, created_at, touched_at, local_copy FROM wanted WHERE quality > 0';
    const order = 'ORDER BY touched_at DESC, created_at DESC, asset_id DESC LIMIT ?';

    final rows = after == null
        ? await _db.getAll('$columns $order', [limit])
        : await _db.getAll(
            '$columns AND (touched_at < ? OR (touched_at = ? '
            'AND (created_at < ? OR (created_at = ? AND asset_id < ?)))) $order',
            [after.touchedAt, after.touchedAt, after.createdAt, after.createdAt, after.id, limit],
          );

    return [
      for (final row in rows)
        OfflineWant(
          id: row['asset_id'] as String,
          quality: OfflineQuality.fromCode(row['quality'] as int),
          createdAt: row['created_at'] as int,
          touchedAt: row['touched_at'] as int,
          localCopy: (row['local_copy'] as int) == 1,
        ),
    ];
  }

  /// What the selection decided, by id, for checking those decisions back against it.
  Future<List<OfflineFlagRow>> derivedPage({String? afterId, required int limit}) async {
    const columns =
        'SELECT asset_id, quality, is_image, has_motion, created_at, touched_at FROM wanted '
        'WHERE quality > 0 AND on_demand = 0';
    const order = 'ORDER BY asset_id LIMIT ?';

    final rows = afterId == null
        ? await _db.getAll('$columns $order', [limit])
        : await _db.getAll('$columns AND asset_id > ? $order', [afterId, limit]);

    return [
      for (final row in rows)
        OfflineFlagRow(
          id: row['asset_id'] as String,
          quality: OfflineQuality.fromCode(row['quality'] as int),
          isImage: (row['is_image'] as int) == 1,
          hasMotion: (row['has_motion'] as int) == 1,
          createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
          touchedAt: DateTime.fromMillisecondsSinceEpoch((row['touched_at'] as int) * 1000),
        ),
    ];
  }

  /// Whether any selected item is missing the thumbnail or preview every rung asks for.
  ///
  /// One `EXISTS` inside SQLite, so a pass can tell in a millisecond whether it has to look past its own budget for
  /// cheap files (`offline_sync.service.dart`). It cannot see a *superseded* copy — the token lives in `held` but the
  /// comparison needs upstream's thumbhash — so a stale preview reads as present here and is picked up by a later pass
  /// instead.
  Future<bool> hasMissingBase() async {
    final base = '${OfflineVariant.thumbnail.index},${OfflineVariant.preview.index}';
    final row = await _db.get(
      'SELECT EXISTS ('
      'SELECT 1 FROM wanted w WHERE w.quality > 0 AND '
      '(SELECT COUNT(*) FROM held h WHERE h.asset_id = w.asset_id AND h.variant IN ($base)) < 2'
      ') AS missing',
    );
    return (row['missing'] as int) == 1;
  }

  /// Every asset that is selected *or* has a file on disk: deselecting never deletes, so an asset can have every file
  /// it needs and no selection.
  Future<List<OfflineIndexRow>> loadIndex() async {
    final thumbnails = '${OfflineVariant.preview.index}';
    final original = '${OfflineVariant.original.index}';
    final video = '${OfflineVariant.video.index}';
    final rows = await _db.getAll('''
      SELECT a.asset_id AS asset_id,
             COALESCE(w.quality, 0) AS quality,
             COALESCE(w.is_image, CASE WHEN SUM(h.variant = $video) > 0 THEN 0 ELSE 1 END) AS is_image,
             COALESCE(w.has_motion, 0) AS has_motion,
             COALESCE(SUM(DISTINCT 1 << h.variant), 0) AS held,
             COALESCE(MAX(CASE WHEN h.variant <= $thumbnails THEN h.token END), 0) AS token,
             COALESCE(MAX(CASE WHEN h.variant = $original THEN h.token END), 0) AS original_token,
             COALESCE(MAX(CASE WHEN h.variant = $video THEN h.token END), 0) AS video_token,
             COALESCE(w.local_copy, 0) AS local_copy,
             COALESCE(w.on_demand, 0) AS on_demand,
             EXISTS (SELECT 1 FROM errands e WHERE e.asset_id = a.asset_id) AS errand
      FROM (SELECT asset_id FROM wanted WHERE quality > 0 UNION SELECT asset_id FROM held) a
      LEFT JOIN wanted w ON w.asset_id = a.asset_id AND w.quality > 0
      LEFT JOIN held h ON h.asset_id = a.asset_id
      GROUP BY a.asset_id
    ''');

    return [
      for (final row in rows)
        OfflineIndexRow(
          assetId: row['asset_id'] as String,
          quality: OfflineQuality.fromCode(row['quality'] as int),
          isImage: (row['is_image'] as int) == 1,
          hasMotion: (row['has_motion'] as int) == 1,
          held: (row['held'] as int?) ?? 0,
          token: (row['token'] as int?) ?? 0,
          originalToken: (row['original_token'] as int?) ?? 0,
          videoToken: (row['video_token'] as int?) ?? 0,
          localCopy: ((row['local_copy'] as int?) ?? 0) == 1,
          errand: ((row['errand'] as int?) ?? 0) == 1,
          onDemand: ((row['on_demand'] as int?) ?? 0) == 1,
        ),
    ];
  }

  /// Files on disk and the space they take.
  Future<(int, int)> heldTotals() async {
    final row = await _db.get('''
      SELECT
        (SELECT COUNT(*) FROM held h JOIN wanted w ON w.asset_id = h.asset_id AND w.quality > 0) AS c,
        (SELECT COALESCE(SUM(size), 0) FROM held) AS b
    ''');
    return (row['c'] as int, row['b'] as int);
  }

  /// When a held file is no longer selected, over the default aliases.
  static final String _unselected = _unselectedOver('h', 'w');

  /// Everything the storage overview shows, in one query — figures that have to add up must not come from six different
  /// moments — and aggregated in SQL, so a six-figure store never becomes a six-figure Dart collection to be counted.
  Future<OfflineStorage> storage() async {
    final base = OfflineVariant.thumbnail.bit | OfflineVariant.preview.bit;
    final original = OfflineVariant.original.index;
    final video = OfflineVariant.video.index;

    final row = await _db.get('''
      WITH file AS (
        SELECT h.asset_id AS asset_id,
               h.variant   AS variant,
               h.size      AS size,
               CASE WHEN ($_unselected) THEN 0 ELSE 1 END AS kept
        FROM held h
        LEFT JOIN wanted w ON w.asset_id = h.asset_id AND w.quality > 0
      ),
      asset AS (
        SELECT h.asset_id AS asset_id,
               COALESCE(SUM(DISTINCT 1 << h.variant), 0) AS mask
        FROM held h
        GROUP BY h.asset_id
      )
      SELECT
        COALESCE(SUM(CASE WHEN f.kept = 1 AND f.variant = $original THEN f.size END), 0) AS kept_original,
        COALESCE(SUM(CASE WHEN f.kept = 1 AND f.variant = $video THEN f.size END), 0) AS kept_video,
        COALESCE(SUM(CASE WHEN f.kept = 1 AND f.variant NOT IN ($_fullSizeVariants) THEN f.size END), 0)
          AS kept_preview,
        COALESCE(SUM(CASE WHEN f.kept = 0 AND f.variant = $original THEN f.size END), 0) AS cached_original,
        COALESCE(SUM(CASE WHEN f.kept = 0 AND f.variant = $video THEN f.size END), 0) AS cached_video,
        COALESCE(SUM(CASE WHEN f.kept = 0 AND f.variant NOT IN ($_fullSizeVariants) THEN f.size END), 0)
          AS cached_preview,
        -- The thumbnail and the preview are what makes anything open off-grid,
        -- videos included: below the top rung a video's still is all that was
        -- ever asked for, so it counts as available rather than as nothing.
        COUNT(DISTINCT CASE WHEN (a.mask & $base) = $base THEN a.asset_id END) AS available_assets
      FROM file f JOIN asset a ON a.asset_id = f.asset_id
    ''');

    return OfflineStorage(
      keptOriginalBytes: row['kept_original'] as int,
      keptVideoBytes: row['kept_video'] as int,
      keptPreviewBytes: row['kept_preview'] as int,
      cachedOriginalBytes: row['cached_original'] as int,
      cachedVideoBytes: row['cached_video'] as int,
      cachedPreviewBytes: row['cached_preview'] as int,
      availableAssets: row['available_assets'] as int,
    );
  }

  /// What "free up space" would do, split by what the user loses: an item that loses its original still opens off-grid,
  /// one that is removed does not.
  Future<OfflineReclaimPlan> reclaimPlan({
    Iterable<String>? assetIds,
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) async {
    final columns =
        '''
        COUNT(*) AS files,
        COALESCE(SUM(h.size), 0) AS bytes,
        COUNT(DISTINCT h.asset_id) AS assets,
        COUNT(DISTINCT CASE WHEN h.variant NOT IN ($_fullSizeVariants) THEN h.asset_id END) AS losing_previews,
        COUNT(DISTINCT CASE WHEN h.variant = ${OfflineVariant.original.index} THEN h.asset_id END)
          AS losing_originals,
        COUNT(DISTINCT CASE WHEN h.variant = ${OfflineVariant.video.index} THEN h.asset_id END) AS losing_videos,
        -- The hand-saved share, by media type: what a removal takes that nothing
        -- on the settings screen ever listed.
        COUNT(DISTINCT CASE WHEN w.on_demand = 1 AND w.is_image = 0 THEN h.asset_id END) AS hand_videos,
        COALESCE(SUM(CASE WHEN w.on_demand = 1 AND w.is_image = 0 THEN h.size END), 0) AS hand_video_bytes,
        COUNT(DISTINCT CASE WHEN w.on_demand = 1 AND w.is_image = 1 THEN h.asset_id END) AS hand_photos,
        COALESCE(SUM(CASE WHEN w.on_demand = 1 AND w.is_image = 1 THEN h.size END), 0) AS hand_photo_bytes''';
    final where = what.sql;

    if (assetIds == null) {
      return _planOf(await _db.get('SELECT $columns $_reclaimFrom WHERE $where'));
    }

    // Chunks partition the ids, so the per-asset `DISTINCT` counts add up.
    var plan = OfflineReclaimPlan.empty;
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      plan += _planOf(
        await _db.get('SELECT $columns $_reclaimFrom WHERE $where AND h.asset_id IN ($placeholders)', chunk),
      );
    }
    return plan;
  }

  static const _reclaimFrom = 'FROM held h LEFT JOIN wanted w ON w.asset_id = h.asset_id AND w.quality > 0';

  // Every column is `COALESCE`d or a `COUNT`, so none can come back null.
  OfflineReclaimPlan _planOf(Map<String, Object?> row) => OfflineReclaimPlan(
    files: row['files']! as int,
    bytes: row['bytes']! as int,
    assets: row['assets']! as int,
    losingPreviews: row['losing_previews']! as int,
    losingOriginals: row['losing_originals']! as int,
    losingVideos: row['losing_videos']! as int,
    handVideos: row['hand_videos']! as int,
    handVideoBytes: row['hand_video_bytes']! as int,
    handPhotos: row['hand_photos']! as int,
    handPhotoBytes: row['hand_photo_bytes']! as int,
  );

  /// What each cell of the choice actually contributes, which is not the same as what it holds: a previews cell gives
  /// up only the previews of items whose full-size copies are going too, and that depends on the rest of the choice.
  Future<Map<OfflineReclaimCell, int>> reclaimBytesByCell(OfflineReclaim what) async {
    if (what.isEmpty) {
      return const {};
    }

    // Positions, not names: the enums are what the screen reads back, and a
    // string here would be a second spelling of them to keep in step.
    final bandCase =
        'CASE WHEN ${_ReclaimWhere.band(OfflineReclaimBand.spares, 'h', 'w')} '
        'THEN ${OfflineReclaimBand.spares.index} ELSE ${OfflineReclaimBand.maintained.index} END';
    final kindCase =
        'CASE '
        'WHEN h.variant = ${OfflineVariant.video.index} THEN ${OfflineReclaimKind.videos.index} '
        'WHEN h.variant = ${OfflineVariant.original.index} THEN ${OfflineReclaimKind.originals.index} '
        'ELSE ${OfflineReclaimKind.previews.index} END';

    final rows = await _db.getAll(
      'SELECT $bandCase AS band, $kindCase AS kind, COALESCE(SUM(h.size), 0) AS bytes '
      '$_reclaimFrom WHERE ${what.sql} GROUP BY band, kind',
    );
    return {
      for (final row in rows)
        (OfflineReclaimBand.values[row['band'] as int], OfflineReclaimKind.values[row['kind'] as int]):
            row['bytes'] as int,
    };
  }

  /// Reclaimable bytes per asset, for the rows that report what their own change left behind.
  Future<Map<String, int>> reclaimableBytesByAsset() async {
    final rows = await _db.getAll(
      'SELECT h.asset_id AS asset_id, SUM(h.size) AS bytes FROM held h '
      'LEFT JOIN wanted w ON w.asset_id = h.asset_id AND w.quality > 0 '
      'WHERE $_unselected GROUP BY h.asset_id',
    );
    return {for (final row in rows) row['asset_id'] as String: row['bytes'] as int};
  }

  /// The reclaimable files among [assetIds]. Unpaged: bounded by the album.
  Future<List<OfflineHeldRow>> reclaimableFilesFor(
    Iterable<String> assetIds, {
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) async {
    final result = <OfflineHeldRow>[];
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _db.getAll(
        'SELECT h.name AS name, h.asset_id AS asset_id, h.variant AS variant, h.token AS token, h.size AS size '
        '$_reclaimFrom '
        'WHERE ${what.sql} AND h.asset_id IN ($placeholders)',
        chunk,
      );
      for (final row in rows) {
        result.add(
          OfflineHeldRow(
            name: row['name'] as String,
            assetId: row['asset_id'] as String,
            variant: OfflineVariant.values[row['variant'] as int],
            token: row['token'] as int,
            size: row['size'] as int,
          ),
        );
      }
    }
    return result;
  }

  /// Every held file, in pages — what the integrity pass is allowed to keep.
  Future<List<OfflineHeldRow>> heldPage({required int limit, String? afterName}) async {
    final rows = await _db.getAll(
      'SELECT name, asset_id, variant, token, size FROM held WHERE name > ? ORDER BY name LIMIT ?',
      [afterName ?? '', limit],
    );
    return [
      for (final row in rows)
        OfflineHeldRow(
          name: row['name'] as String,
          assetId: row['asset_id'] as String,
          variant: OfflineVariant.values[row['variant'] as int],
          token: row['token'] as int,
          size: row['size'] as int,
        ),
    ];
  }

  /// Those files, in pages, for the reclaim itself.
  Future<List<OfflineHeldRow>> reclaimableFiles({
    required int limit,
    String? afterName,
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) async {
    final rows = await _db.getAll(
      'SELECT h.name AS name, h.asset_id AS asset_id, h.variant AS variant, h.token AS token, h.size AS size '
      '$_reclaimFrom '
      'WHERE ${what.sql} AND h.name > ? ORDER BY h.name LIMIT ?',
      [afterName ?? '', limit],
    );
    return [
      for (final row in rows)
        OfflineHeldRow(
          name: row['name'] as String,
          assetId: row['asset_id'] as String,
          variant: OfflineVariant.values[row['variant'] as int],
          token: row['token'] as int,
          size: row['size'] as int,
        ),
    ];
  }

  /// Drops on-demand rows whose files have all gone, so a fetched item stops counting as wanted once "free up space"
  /// has taken it back.
  Future<void> dropFetchedWithoutFiles() async {
    await _db.execute(
      'DELETE FROM wanted WHERE on_demand = 1 '
      'AND asset_id NOT IN (SELECT DISTINCT asset_id FROM held)',
    );
    revision++;
  }

  /// Forgets selection-derived rows the current selection no longer covers.
  Future<void> dropUnselected(Iterable<String> assetIds) async {
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _db.execute('DELETE FROM wanted WHERE on_demand = 0 AND asset_id IN ($placeholders)', chunk);
    }
    revision++;
  }

  /// Forgets decisions outright, for assets upstream no longer has at all.
  Future<void> forget(Iterable<String> assetIds) async {
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _db.execute('DELETE FROM wanted WHERE asset_id IN ($placeholders)', chunk);
      await _db.execute('DELETE FROM errands WHERE asset_id IN ($placeholders)', chunk);
    }
    revision++;
  }

  /// Assets asked for by hand and not yet complete, which the queue puts before all standing work (FORK.md §3.3).
  ///
  /// Read whole rather than paged or joined: it holds what the user tapped and nothing else, and a pass needs the set
  /// before it can rank anything.
  Future<Set<String>> errands() async {
    final rows = await _db.getAll('SELECT asset_id FROM errands');
    return {for (final row in rows) row['asset_id'] as String};
  }

  Future<void> addErrands(Iterable<String> assetIds) async {
    final ids = assetIds.toList();
    if (ids.isEmpty) {
      return;
    }
    await _db.executeBatch('INSERT OR IGNORE INTO errands (asset_id) VALUES (?)', [
      for (final id in ids) [id],
    ]);
    revision++;
  }

  /// Drops the mark, for an errand that has arrived or been taken back. Not a decision about the files: what a selection
  /// maintains is untouched, and the copies stay on disk either way.
  Future<void> dropErrands(Iterable<String> assetIds) async {
    final ids = assetIds.toList();
    if (ids.isEmpty) {
      return;
    }
    for (final chunk in _chunked(ids)) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _db.execute('DELETE FROM errands WHERE asset_id IN ($placeholders)', chunk);
    }
    revision++;
  }

  /// Assets among [assetIds] that have never been decided about, so policy may still apply to them.
  Future<Set<String>> undecided(Iterable<String> assetIds) async {
    final ids = assetIds.toList();
    final decided = <String>{};
    for (final chunk in _chunked(ids)) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      for (final row in await _db.getAll('SELECT asset_id FROM wanted WHERE asset_id IN ($placeholders)', chunk)) {
        decided.add(row['asset_id'] as String);
      }
    }
    return ids.toSet()..removeAll(decided);
  }

  /// What is already recorded for [assetIds], so a derivation can write only the rows that actually change.
  ///
  /// A library-wide walk is the answer to any mismatch the incremental paths cannot express, and this is what makes it
  /// affordable: without it the walk costs one write per asset and re-stamps `touched_at` across the library, which
  /// reorders the queue for work nobody changed.
  Future<Map<String, ({OfflineQuality quality, bool hasMotion})>> decisionsFor(Iterable<String> assetIds) async {
    final ids = assetIds.toList();
    final decisions = <String, ({OfflineQuality quality, bool hasMotion})>{};
    for (final chunk in _chunked(ids)) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _db.getAll(
        'SELECT asset_id, quality, has_motion FROM wanted WHERE asset_id IN ($placeholders)',
        chunk,
      );
      for (final row in rows) {
        decisions[row['asset_id'] as String] = (
          quality: OfflineQuality.fromCode(row['quality'] as int),
          hasMotion: (row['has_motion'] as int) == 1,
        );
      }
    }
    return decisions;
  }

  // --------------------------------------------------------------------------- Writing

  /// Records decisions, one write for a whole library.
  Future<void> set(Iterable<OfflineFlagRow> assets) async {
    final rows = [
      for (final row in assets)
        [
          row.id,
          row.quality.code,
          row.isImage ? 1 : 0,
          row.hasMotion ? 1 : 0,
          row.createdAt.millisecondsSinceEpoch,
          row.onDemand ? 1 : 0,
          // Whole seconds, and truncated in exactly one place.
          row.touchedAt.millisecondsSinceEpoch ~/ 1000,
        ],
    ];
    if (rows.isEmpty) {
      return;
    }
    // An upsert naming its columns, not `INSERT OR REPLACE`: replacing the row resets every column the statement does
    // not mention, and `local_copy` is not one a decision knows about — it describes the camera roll, is read from
    // upstream's database by the pass, and re-deriving the library would otherwise wipe the lot and file every
    // hand-saved original as library until the next walk put it back.
    await _db.executeBatch(
      'INSERT INTO wanted (asset_id, quality, is_image, has_motion, created_at, on_demand, touched_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(asset_id) DO UPDATE SET '
      'quality = excluded.quality, is_image = excluded.is_image, has_motion = excluded.has_motion, '
      'created_at = excluded.created_at, on_demand = excluded.on_demand, touched_at = excluded.touched_at',
      rows,
    );
    revision++;
  }

  /// Records which items the camera roll holds a usable original of, so the reclaim bands can tell a hand-saved spare
  /// from a copy a selection maintains (`_unselectedOver`).
  ///
  /// A column rather than a live join, because the two facts live in two databases (§3.2.1) — and refreshed by every
  /// pass rather than written once, because this is the most volatile input the mirror has: upstream's *Free Up Space*
  /// exists to delete those local originals, and the moment one goes the mirror owes that item a full copy again. The
  /// fingerprint counts local assets for the same reason, so a camera roll that changed wakes a pass that fixes this.
  ///
  /// Deliberately does not bump [revision]: it re-files bytes already on disk and changes nothing about what is wanted
  /// or held, and treating it as a change would have every pass conclude that something moved.
  Future<void> setLocalCopy(Map<String, bool> byAssetId) async {
    if (byAssetId.isEmpty) {
      return;
    }
    await _db.executeBatch('UPDATE wanted SET local_copy = ? WHERE asset_id = ?', [
      for (final entry in byAssetId.entries) [entry.value ? 1 : 0, entry.key],
    ]);
  }

  /// Records files that have arrived, at most one per asset and variant.
  Future<void> markHeld(Iterable<OfflineHeldRow> files) async {
    final held = files.toList();
    if (held.isEmpty) {
      return;
    }
    await _db.executeBatch('DELETE FROM held WHERE asset_id = ? AND variant = ? AND name <> ?', [
      for (final file in held) [file.assetId, file.variant.index, file.name],
    ]);
    await _db.executeBatch(
      'INSERT OR REPLACE INTO held (name, asset_id, variant, token, size) VALUES (?, ?, ?, ?, ?)',
      [
        for (final file in held) [file.name, file.assetId, file.variant.index, file.token, file.size],
      ],
    );
  }

  Future<void> dropHeld(Iterable<String> names) async {
    for (final chunk in _chunked(names.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _db.execute('DELETE FROM held WHERE name IN ($placeholders)', chunk);
    }
  }

  Future<void> clearHeld() => _db.execute('DELETE FROM held');

  // --------------------------------------------------------------------------- Failures

  /// Attempts before a file is left alone: enough to ride out a restart or a server hiccup without hammering something
  /// broken.
  static const _maxAttempts = 3;

  Future<void> recordFailure(String name) => _db.execute(
    'INSERT INTO failures (name, attempts) VALUES (?, 1) ON CONFLICT(name) DO UPDATE SET attempts = attempts + 1',
    [name],
  );

  Future<void> clearFailure(String name) => _db.execute('DELETE FROM failures WHERE name = ?', [name]);

  /// Names that have failed too often to keep trying.
  Future<Set<String>> abandoned() async => {
    for (final row in await _db.getAll('SELECT name FROM failures WHERE attempts >= ?', [_maxAttempts]))
      row['name'] as String,
  };

  Future<int> abandonedCount() async =>
      (await _db.get('SELECT COUNT(*) AS c FROM failures WHERE attempts >= ?', [_maxAttempts]))['c'] as int;

  Future<void> forgetFailures() async {
    await _db.execute('DELETE FROM failures');
    revision++;
  }

  // --------------------------------------------------------------------------- Meta

  Future<String?> _meta(String key) async {
    final row = await _db.getOptional('SELECT value FROM meta WHERE key = ?', [key]);
    return row == null ? null : row['value'] as String;
  }

  Future<void> _setMeta(String key, String? value) async {
    if (value == null) {
      await _db.execute('DELETE FROM meta WHERE key = ?', [key]);
      return;
    }
    await _db.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [key, value]);
  }

  /// Upstream `updatedAt` of the newest asset policy has been applied to, with the id that broke the tie.
  Future<(DateTime, String)?> policyWatermark() async {
    final raw = await _meta('policy_watermark');
    if (raw == null) {
      return null;
    }
    final split = raw.indexOf(':');
    final millis = int.tryParse(split < 0 ? raw : raw.substring(0, split));
    if (millis == null) {
      return null;
    }
    return (DateTime.fromMillisecondsSinceEpoch(millis), split < 0 ? '' : raw.substring(split + 1));
  }

  Future<void> setPolicyWatermark((DateTime, String)? value) =>
      _setMeta('policy_watermark', value == null ? null : '${value.$1.millisecondsSinceEpoch}:${value.$2}');

  /// When the store was last walked end to end.
  Future<DateTime?> lastReclaim() async {
    final millis = int.tryParse(await _meta('last_reclaim') ?? '');
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// Records a completed walk, which is also what clears [reclaimPending].
  Future<void> setReclaimed(DateTime at) async {
    await _setMeta('last_reclaim', at.millisecondsSinceEpoch.toString());
    await _setMeta('reclaim_pending', null);
  }

  /// Whether a walk stopped without finishing its job, so the next launch should try again rather than wait out the
  /// interval — the conditions it stops for clear in minutes.
  Future<bool> reclaimPending() async => await _meta('reclaim_pending') != null;

  Future<void> setReclaimPending() => _setMeta('reclaim_pending', '1');

  /// Which video the store was filled with, `original` or `video/playback`.
  Future<String?> videoForm() => _meta('video_form');

  Future<void> setVideoForm(String value) => _setMeta('video_form', value);

  /// How many assets each album the selection names held at the last pass.
  Future<Map<String, int>> albumSizes() async {
    final raw = await _meta('album_sizes');
    if (raw == null || raw.isEmpty) {
      return const {};
    }
    try {
      return {
        for (final entry in (jsonDecode(raw) as Map<String, dynamic>).entries)
          if (entry.value case final int size) entry.key: size,
      };
    } catch (error) {
      // A value that cannot be read costs one re-derivation, so it degrades to
      // "nothing remembered" rather than throwing on a pass that runs at launch.
      Logger('OfflineFlags').warning('Could not read the album sizes; every named album is re-derived', error);
      return const {};
    }
  }

  Future<void> setAlbumSizes(Map<String, int> sizes) =>
      _setMeta('album_sizes', sizes.isEmpty ? null : jsonEncode(sizes));

  /// SQLite's variable limit is 999 by default; this stays well inside it.
  Iterable<List<String>> _chunked(List<String> ids) sync* {
    for (var i = 0; i < ids.length; i += 500) {
      yield ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
    }
  }
}

