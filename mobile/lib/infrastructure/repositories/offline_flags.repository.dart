/// immich-sync fork: which assets are wanted on this device (`wanted`) and which of their files are here (`held`). The
/// tables live in the fork's own file, attached to upstream's connection as the `offline` schema (see
/// `offline_paths.dart`).
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/infrastructure/repositories/offline.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException, sqlite3;

/// Originals and playable files: the expensive, optional part of an asset.
final String _fullSizeVariants = '${OfflineVariant.original.index},${OfflineVariant.video.index}';

/// Whether the camera roll holds a usable original of the asset at alias [a]: `OfflineAsset.localCopyUsable` in SQL.
/// Asked live rather than stored, so it cannot go stale. `EXISTS` rather than a join, since a checksum can match
/// several rows. An edited asset never counts: the local file is the pre-edit one.
String _localCopyUsable(String a) =>
    '($a.is_edited = 0 '
    ' AND EXISTS (SELECT 1 FROM main.local_asset_entity dev WHERE dev.checksum = $a.checksum))';

/// Whether a held file is maintained by nothing, over the aliases [h] (held), [w] (wanted) and [a] (the upstream
/// asset).
///
/// A file is a spare when no selection wants its asset, when the asset is gone upstream, when it was saved by hand,
/// when it is a full-size file the camera roll already holds, or when it is above what the row's rung asks for. A Live
/// Photo's video counts as a file of its photo. A trashed asset is selected by nothing, so its copies are spares: the
/// integrity pass keeps them while it can be restored, and eviction may take them.
///
/// An asset only counts as gone once upstream is complete (see [OfflineFlagsRepository.vouch]): right after sign-in or
/// a server reset every asset is missing for a while. Unknown is never a spare, hence the `COALESCE`.
String _unselectedOver(String h, String w, String a) =>
    'COALESCE(('
    '$w.asset_id IS NULL '
    "OR ($a.id IS NULL AND EXISTS (SELECT 1 FROM meta WHERE key = '${OfflineFlagsRepository._upstreamCompleteKey}')) "
    'OR $w.on_demand = 1 '
    'OR ($h.variant IN ($_fullSizeVariants) AND ${_localCopyUsable(a)}) '
    'OR ($h.variant = ${OfflineVariant.preview.index} AND $w.quality < ${OfflineQuality.preview.code}) '
    'OR ($h.variant = ${OfflineVariant.original.index} '
    '    AND NOT ($a.type = ${AssetType.image.index} AND $w.quality >= ${OfflineQuality.full.code})) '
    'OR ($h.variant = ${OfflineVariant.video.index} '
    '    AND NOT (($a.type <> ${AssetType.image.index} OR $a.live_photo_video_id IS NOT NULL) '
    '             AND $w.quality >= ${OfflineQuality.fullWithVideos.code}))'
    '), 0)';

extension _ReclaimSql on OfflineReclaimKind {
  String get variants => switch (this) {
    OfflineReclaimKind.videos => '${OfflineVariant.video.index}',
    OfflineReclaimKind.originals => '${OfflineVariant.original.index}',
    OfflineReclaimKind.previews => '${OfflineVariant.preview.index}',
    OfflineReclaimKind.thumbnails => '${OfflineVariant.thumbnail.index}',
  };
}

/// One reclaim choice as a `WHERE` clause, so the figure a screen quotes and the files a deletion takes are the same
/// set.
extension _ReclaimWhere on OfflineReclaim {
  static String band(OfflineReclaimBand band, String h, String w, String a) => switch (band) {
    OfflineReclaimBand.spares => '(${_unselectedOver(h, w, a)})',
    OfflineReclaimBand.maintained => 'NOT (${_unselectedOver(h, w, a)})',
  };

  /// Every ticked cell, one band-and-kind pair per `OR`.
  String cellsOver(String h, String w, String a) {
    if (cells.isEmpty) {
      return '0';
    }
    return cells.map((cell) => '(${band(cell.$1, h, w, a)} AND $h.variant IN (${cell.$2.variants}))').join(' OR ');
  }

  /// The ticked cells, minus files something bigger of the same item still needs: a preview goes only if no full-size
  /// copy stays, a thumbnail only if neither a full-size copy nor a preview does.
  String get sql {
    if (cells.isEmpty) {
      return '0';
    }
    String survivor(String variants) =>
        'SELECT 1 FROM held g '
        'LEFT JOIN wanted wg ON wg.asset_id = g.asset_id AND wg.quality > 0 '
        'LEFT JOIN main.remote_asset_entity ag ON ag.id = g.asset_id '
        'WHERE g.asset_id = h.asset_id AND g.variant IN ($variants) '
        'AND NOT (${cellsOver('g', 'wg', 'ag')})';
    final preview = OfflineVariant.preview.index;
    final thumbnail = OfflineVariant.thumbnail.index;
    return '(${cellsOver('h', 'w', 'a')}) '
        'AND (h.variant IN ($_fullSizeVariants) '
        '  OR (h.variant = $preview AND NOT EXISTS (${survivor(_fullSizeVariants)})) '
        '  OR (h.variant = $thumbnail AND NOT EXISTS (${survivor('$_fullSizeVariants,$preview')})))';
  }
}

class OfflineFlagsRepository {
  OfflineFlagsRepository._(this._db, [this._path]);

  final Drift _db;

  /// The file, so a query that finds it corrupt can have [prepareFile] set it aside at the next launch.
  final String? _path;

  static OfflineFlagsRepository? _opened;

  /// Available once [ensureInitialized] has run during bootstrap.
  static OfflineFlagsRepository get instance {
    final opened = _opened;
    if (opened == null) {
      throw StateError('OfflineFlagsRepository.ensureInitialized() must run during bootstrap');
    }
    return opened;
  }

  /// Never fails the launch over the mirror: a schema that cannot be brought up to date is logged, and the mirror's own
  /// passes report their errors. A clash with an upstream table name still throws, since every query would then read
  /// upstream's table; the tests catch it on a rebase.
  static Future<OfflineFlagsRepository> ensureInitialized(Drift db, {String? path}) async {
    final existing = _opened;
    if (existing != null) {
      return existing;
    }
    final instance = OfflineFlagsRepository._(db, path);
    try {
      await instance.ensureSchema();
    } on OfflineSchemaClash {
      rethrow;
    } catch (error, stackTrace) {
      Logger('OfflineFlagsRepository').severe('Could not prepare the offline database; continuing', error, stackTrace);
    }
    return _opened = instance;
  }

  /// Runs before the file is attached, once per launch and from the main isolate only: worker isolates run beside its
  /// open connections, and moving the file under them would split their writes from its WAL. A file SQLite reports as
  /// corrupt or not a database is set aside and a fresh one started. Opening only reads the schema, so damage further
  /// in is found by the queries that hit it, which leave a mark for this to act on at the next launch. The selection
  /// lives in upstream's settings, so the next pass re-derives the decisions, files on disk are claimed again as passes
  /// want them, and the integrity pass sweeps the rest; items saved by hand and not selected are forgotten. Any other
  /// error (a busy file) leaves the file alone.
  static Future<void> prepareFile(String path) async {
    final file = File(path);
    final mark = File('$path$_corruptMark');
    if (!file.existsSync()) {
      _deleteIfThere(mark);
      return;
    }
    Object? unreadable = mark.existsSync() ? 'a query found it corrupt' : null;
    if (unreadable == null) {
      try {
        final db = sqlite3.open(path);
        try {
          db.execute('PRAGMA busy_timeout = 10000');
          db.select('SELECT COUNT(*) FROM sqlite_master');
        } finally {
          db.close();
        }
      } on SqliteException catch (error) {
        if (!_isCorrupt(error)) {
          Logger('OfflineFlagsRepository').warning('Could not check the offline database', error);
          return;
        }
        unreadable = error;
      }
    }
    if (unreadable == null) {
      return;
    }
    // A background engine may still have it open; the mark stays for the next launch.
    if (_inUse(path)) {
      Logger('OfflineFlagsRepository').warning('The offline database is unreadable but in use; set aside later');
      return;
    }
    Logger('OfflineFlagsRepository').severe('The offline database is unreadable; starting a new one', unreadable);
    for (final suffix in const ['', '-wal', '-shm']) {
      final part = File('$path$suffix');
      if (part.existsSync()) {
        part.renameSync('$path.corrupt$suffix');
      }
    }
    _deleteIfThere(mark);
  }

  /// Whether another connection has the file open, which moving it would split from its WAL. Without a busy timeout, an
  /// exclusive lock fails at once while any other connection holds the file.
  static bool _inUse(String path) {
    try {
      final db = sqlite3.open(path);
      try {
        db.execute('PRAGMA locking_mode = EXCLUSIVE');
        db.execute('BEGIN EXCLUSIVE');
        db.execute('COMMIT');
      } finally {
        db.close();
      }
      return false;
    } on SqliteException catch (error) {
      return error.resultCode == _sqliteBusy || error.resultCode == _sqliteLocked;
    }
  }

  static const _sqliteBusy = 5;
  static const _sqliteLocked = 6;

  /// Beside the file: a query found it corrupt, so the next launch sets it aside.
  static const _corruptMark = '.unreadable';

  /// Whether SQLite finds damage in the fork's own file. Unknown counts as no, so nothing is set aside on a guess.
  Future<bool> _ownFileCorrupt() async {
    try {
      final rows = await _db.customSelect('PRAGMA $kOfflineSchema.quick_check(1)').get();
      return rows.isEmpty || rows.first.data.values.first != 'ok';
    } catch (error) {
      return _isCorrupt(error);
    }
  }

  static bool _isCorrupt(Object error) =>
      error is SqliteException && (error.resultCode == _sqliteCorrupt || error.resultCode == _sqliteNotADatabase);

  static const _sqliteCorrupt = 11;
  static const _sqliteNotADatabase = 26;

  static void _deleteIfThere(File file) {
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  /// Runs a query, and marks the file for [prepareFile] if SQLite reports it corrupt. Most queries also read upstream's
  /// file, so the fork's own is checked before it is blamed: setting it aside forgets hand-saved items and could not
  /// mend upstream's.
  Future<T> _marking<T>(Future<T> Function() query) async {
    try {
      return await query();
    } catch (error) {
      final path = _path;
      if (path != null && _isCorrupt(error) && await _ownFileCorrupt()) {
        try {
          File('$path$_corruptMark').createSync();
        } catch (_) {
          // The next query that fails tries again.
        }
      }
      rethrow;
    }
  }

  @visibleForTesting
  static Future<OfflineFlagsRepository> forConnection(Drift db, {String? path}) async {
    final instance = OfflineFlagsRepository._(db, path);
    await instance.ensureSchema();
    return instance;
  }

  /// Marks one-off upgrades of unversioned files as done, for files written by builds that had them but no version.
  static const _failuresClassifiedKey = 'failures_classified';

  static const _rungsRenumberedKey = 'rungs_renumbered';

  /// Set once a foreground remote sync has finished, cleared whenever upstream wipes its remote tables. Until then
  /// upstream's tables may hold assets without their albums, which looks like albums deleted on the server.
  static const _upstreamCompleteKey = 'upstream_complete';

  /// Bumped by every upstream reset, so a sync can tell whether one landed after it started (see
  /// [setUpstreamComplete]).
  static const _resetGenerationKey = 'reset_generation';

  /// The tables this file uses, which upstream must not have in `main`.
  static const _tables = ['wanted', 'held', 'failures', 'meta'];

  /// Brings the file up to [schemaVersion], on every launch. Not a drift migration: the fork stays out of upstream's
  /// `schemaVersion`. Each step moves the file from the version before it, in the same transaction as the version
  /// bump, so a step runs once per file.
  @visibleForTesting
  Future<void> ensureSchema() async {
    assert(_steps.length == schemaVersion, 'schemaVersion must match the steps');
    await _guardNames();
    await _ensureWal();
    await _db.transaction(() async {
      // Read inside the transaction: every isolate runs this at launch.
      final version = (await _one('PRAGMA $kOfflineSchema.user_version')).data['user_version'] as int;
      if (version > schemaVersion) {
        // Written by a newer build. Its steps only added, so this build reads what it knows and leaves the mark.
        return;
      }
      for (var step = version; step < _steps.length; step++) {
        await _steps[step]();
      }
      await _exec('PRAGMA $kOfflineSchema.user_version = $schemaVersion');
    });
  }

  /// One entry per version; append to change the schema, never edit an entry a release has run.
  late final List<Future<void> Function()> _steps = [_fromUnversioned];

  /// The version [ensureSchema] leaves a file at.
  static const schemaVersion = 1;

  /// Version 1: every file from before versions, from a new one to the oldest fork build's, probed and brought to the
  /// first versioned schema.
  Future<void> _fromUnversioned() async {
    // Only the DDL names the schema. Elsewhere unqualified names resolve here, because [_guardNames] ensures `main`
    // has none.
    await _exec('''
      CREATE TABLE IF NOT EXISTS $kOfflineSchema.wanted (
        asset_id   TEXT PRIMARY KEY,
        quality    INTEGER NOT NULL,
        -- Copied from the asset so the queue index can page by it.
        created_at INTEGER NOT NULL,
        on_demand  INTEGER NOT NULL DEFAULT 0,
        touched_at INTEGER NOT NULL DEFAULT 0,
        -- *Save offline* outstanding. Unlike `on_demand`, also set when a selection covers the asset.
        pinned     INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // Columns older builds wrote that are now asked of upstream instead.
    final columns = {
      for (final column in await _all('PRAGMA $kOfflineSchema.table_info(wanted)')) column.data['name'] as String,
    };
    for (final stale in const ['is_image', 'has_motion', 'local_copy']) {
      if (columns.contains(stale)) {
        await _exec('ALTER TABLE $kOfflineSchema.wanted DROP COLUMN $stale');
      }
    }
    if (!columns.contains('pinned') && columns.isNotEmpty) {
      await _exec('ALTER TABLE $kOfflineSchema.wanted ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
    }
    // The errands table older builds kept, carried over as the `pinned` mark.
    final tables = {
      for (final row in await _all("SELECT name FROM $kOfflineSchema.sqlite_master WHERE type = 'table'"))
        row.data['name'] as String,
    };
    if (tables.contains('errands')) {
      await _exec('UPDATE $kOfflineSchema.wanted SET pinned = 1 WHERE asset_id IN (SELECT asset_id FROM errands)');
      await _exec('DROP TABLE $kOfflineSchema.errands');
    }
    // The order the reconciler pages in. The asset id breaks ties so paging can use a cursor.
    await _exec(
      'CREATE INDEX IF NOT EXISTS $kOfflineSchema.idx_wanted_queue '
      'ON wanted (touched_at DESC, created_at DESC, asset_id DESC)',
    );
    await _exec('''
      CREATE TABLE IF NOT EXISTS $kOfflineSchema.held (
        name     TEXT PRIMARY KEY,
        asset_id TEXT NOT NULL,
        variant  INTEGER NOT NULL,
        token    INTEGER NOT NULL,
        size     INTEGER NOT NULL,
        -- When the file was last stored or shown, in seconds; eviction takes the oldest first.
        used_at  INTEGER NOT NULL DEFAULT 0
      )
    ''');
    final heldColumns = {
      for (final column in await _all('PRAGMA $kOfflineSchema.table_info(held)')) column.data['name'] as String,
    };
    if (!heldColumns.contains('used_at')) {
      // Older rows read as never used, so they are the first spares to go.
      await _exec('ALTER TABLE $kOfflineSchema.held ADD COLUMN used_at INTEGER NOT NULL DEFAULT 0');
    }
    await _exec('CREATE INDEX IF NOT EXISTS $kOfflineSchema.idx_held_asset ON held (asset_id)');
    await _exec('CREATE TABLE IF NOT EXISTS $kOfflineSchema.meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    // Builds from before the readiness mark synced without one; a library already there is taken as complete, or the
    // mirror would wait for a sync that reaches the server before honouring a lowered selection.
    await _exec(
      'INSERT OR IGNORE INTO $kOfflineSchema.meta (key, value) '
      'SELECT ?, ? WHERE EXISTS (SELECT 1 FROM main.remote_asset_entity)',
      [_upstreamCompleteKey, '1'],
    );
    // Files the server will not give us, given up on after a few attempts.
    await _exec('''
      CREATE TABLE IF NOT EXISTS $kOfflineSchema.failures (
        name     TEXT PRIMARY KEY,
        attempts INTEGER NOT NULL DEFAULT 1
      )
    ''');
    // Older builds counted every failure, network ones included, so their list is forgotten once.
    final classified = await _all('SELECT 1 FROM $kOfflineSchema.meta WHERE key = ?', [_failuresClassifiedKey]);
    if (classified.isEmpty) {
      await _exec('DELETE FROM $kOfflineSchema.failures');
      await _exec('INSERT INTO $kOfflineSchema.meta (key, value) VALUES (?, ?)', [_failuresClassifiedKey, '1']);
    }
    // Older builds numbered the rungs one lower before the thumbnail rung existed. Renumbered once, in this
    // transaction, so the integrity pass never reads old codes as new ones.
    final renumbered = await _all('SELECT 1 FROM $kOfflineSchema.meta WHERE key = ?', [_rungsRenumberedKey]);
    if (renumbered.isEmpty) {
      await _exec('UPDATE $kOfflineSchema.wanted SET quality = quality + 1 WHERE quality > 0');
      await _exec('INSERT INTO $kOfflineSchema.meta (key, value) VALUES (?, ?)', [_rungsRenumberedKey, '1']);
    }
    // The timeline bucket cache older builds kept here.
    await _exec('DROP TABLE IF EXISTS $kOfflineSchema.timeline_buckets');
    await _exec('DROP TABLE IF EXISTS $kOfflineSchema.timeline_buckets_cleared');
    // When older builds' downloader tasks were first seen.
    await _exec("DELETE FROM $kOfflineSchema.meta WHERE key = 'outstanding_since'");
  }

  /// Fails loudly if upstream gains a table named like one of ours, which would silently shadow it.
  Future<void> _guardNames() async {
    final clash = await _all(
      "SELECT name FROM main.sqlite_master WHERE type = 'table' AND name IN "
      "(${List.filled(_tables.length, '?').join(',')})",
      _tables,
    );
    if (clash.isNotEmpty) {
      throw OfflineSchemaClash(
        'Upstream now has a table named ${clash.map((row) => row.data['name']).join(', ')}, which would shadow the '
        "fork's own. Qualify every statement in offline_flags.repository.dart, or rename the fork's table.",
      );
    }
  }

  /// Puts the fork's file in WAL mode, like upstream's. An ATTACH does not inherit the journal mode, and WAL is stored
  /// in the file, so once covers every connection. Outside the schema transaction, where the mode cannot change.
  Future<void> _ensureWal() => _exec('PRAGMA $kOfflineSchema.journal_mode = WAL');

  // Hand-written SQL rather than drift's builder, so a figure on screen and the files a deletion takes share one
  // expression.

  static List<Variable> _vars(Iterable<Object?> args) => [
    for (final arg in args)
      switch (arg) {
        null => const Variable<String>(null),
        final int value => Variable<int>(value),
        final double value => Variable<double>(value),
        final bool value => Variable<bool>(value),
        final String value => Variable<String>(value),
        _ => throw ArgumentError('Unsupported SQL argument: $arg'),
      },
  ];

  /// The thumbhash of a synced remote asset, which names its current version; null when it is not synced. Reads only
  /// upstream's table, so it never marks the fork's file.
  Future<String?> thumbHashOf(String assetId) async {
    final row = await _db
        .customSelect('SELECT thumb_hash FROM main.remote_asset_entity WHERE id = ?', variables: [Variable(assetId)])
        .getSingleOrNull();
    return row?.read<String?>('thumb_hash');
  }

  Future<List<QueryRow>> _all(String sql, [List<Object?> args = const []]) =>
      _marking(() => _db.customSelect(sql, variables: _vars(args)).get());

  Future<QueryRow> _one(String sql, [List<Object?> args = const []]) =>
      _marking(() => _db.customSelect(sql, variables: _vars(args)).getSingle());

  Future<QueryRow?> _oneOrNull(String sql, [List<Object?> args = const []]) =>
      _marking(() => _db.customSelect(sql, variables: _vars(args)).getSingleOrNull());

  Future<void> _exec(String sql, [List<Object?> args = const []]) => _marking(() => _db.customStatement(sql, args));

  Future<void> _execEach(String sql, List<List<Object?>> rows) async {
    if (rows.isEmpty) {
      return;
    }
    await _db.transaction(() async {
      for (final row in rows) {
        await _exec(sql, row);
      }
    });
  }

  /// Bumped on every write, so callers can tell derived data is stale.
  int revision = 0;

  /// Wanted assets, most recently decided first, newest photo first within a decision. Includes rows whose asset is
  /// gone upstream, which is what the passes that forget them look for.
  Future<List<OfflineWant>> page({OfflineWantCursor? after, required int limit}) async {
    final columns =
        'SELECT w.asset_id AS asset_id, w.quality AS quality, w.created_at AS created_at, '
        'w.touched_at AS touched_at, COALESCE(${_localCopyUsable('a')}, 0) AS local_copy '
        'FROM wanted w LEFT JOIN main.remote_asset_entity a ON a.id = w.asset_id '
        'WHERE w.quality > 0';
    const order = 'ORDER BY w.touched_at DESC, w.created_at DESC, w.asset_id DESC LIMIT ?';

    final rows = after == null
        ? await _all('$columns $order', [limit])
        : await _all(
            '$columns AND (w.touched_at < ? OR (w.touched_at = ? '
            'AND (w.created_at < ? OR (w.created_at = ? AND w.asset_id < ?)))) $order',
            [after.touchedAt, after.touchedAt, after.createdAt, after.createdAt, after.id, limit],
          );

    return [
      for (final row in rows)
        OfflineWant(
          id: row.data['asset_id'] as String,
          quality: OfflineQuality.fromCode(row.data['quality'] as int),
          createdAt: row.data['created_at'] as int,
          touchedAt: row.data['touched_at'] as int,
          localCopy: (row.data['local_copy'] as int) == 1,
        ),
    ];
  }

  /// Whether any wanted item is missing a thumbnail or preview its rung asks for. It cannot see a copy under an
  /// outdated thumbhash; a later pass picks those up.
  Future<bool> hasMissingBase() async {
    final thumbnail = OfflineVariant.thumbnail.index;
    final preview = OfflineVariant.preview.index;
    final keepsPreview = 'w.quality >= ${OfflineQuality.preview.code}';
    final row = await _one(
      'SELECT EXISTS ('
      'SELECT 1 FROM wanted w WHERE w.quality > 0 AND '
      '(SELECT COUNT(*) FROM held h WHERE h.asset_id = w.asset_id '
      ' AND (h.variant = $thumbnail OR (h.variant = $preview AND $keepsPreview))) '
      '< CASE WHEN $keepsPreview THEN 2 ELSE 1 END'
      ') AS missing',
    );
    return (row.data['missing'] as int) == 1;
  }

  /// Every asset that is wanted or has a file here; deselecting never deletes.
  Future<List<OfflineIndexRow>> loadIndex() async {
    final thumbnails = '${OfflineVariant.preview.index}';
    final original = '${OfflineVariant.original.index}';
    final video = '${OfflineVariant.video.index}';
    final rows = await _all('''
      SELECT k.asset_id AS asset_id,
             COALESCE(w.quality, 0) AS quality,
             -- For an asset gone upstream, a stored video is the only hint of its type.
             COALESCE(a.type = ${AssetType.image.index},
                      CASE WHEN SUM(h.variant = $video) > 0 THEN 0 ELSE 1 END) AS is_image,
             COALESCE(a.live_photo_video_id IS NOT NULL, 0) AS has_motion,
             COALESCE(SUM(DISTINCT 1 << h.variant), 0) AS held,
             COALESCE(MAX(CASE WHEN h.variant <= $thumbnails THEN h.token END), 0) AS token,
             COALESCE(MAX(CASE WHEN h.variant = $original THEN h.token END), 0) AS original_token,
             COALESCE(MAX(CASE WHEN h.variant = $video THEN h.token END), 0) AS video_token,
             COALESCE(${_localCopyUsable('a')}, 0) AS local_copy,
             COALESCE(w.on_demand, 0) AS on_demand,
             COALESCE(w.pinned, 0) AS errand
      FROM (SELECT asset_id FROM wanted WHERE quality > 0 UNION SELECT asset_id FROM held) k
      LEFT JOIN wanted w ON w.asset_id = k.asset_id AND w.quality > 0
      LEFT JOIN held h ON h.asset_id = k.asset_id
      LEFT JOIN main.remote_asset_entity a ON a.id = k.asset_id
      GROUP BY k.asset_id
    ''');

    return [
      for (final row in rows)
        OfflineIndexRow(
          assetId: row.data['asset_id'] as String,
          quality: OfflineQuality.fromCode(row.data['quality'] as int),
          isImage: (row.data['is_image'] as int) == 1,
          hasMotion: (row.data['has_motion'] as int) == 1,
          held: (row.data['held'] as int?) ?? 0,
          token: (row.data['token'] as int?) ?? 0,
          originalToken: (row.data['original_token'] as int?) ?? 0,
          videoToken: (row.data['video_token'] as int?) ?? 0,
          localCopy: ((row.data['local_copy'] as int?) ?? 0) == 1,
          errand: ((row.data['errand'] as int?) ?? 0) == 1,
          onDemand: ((row.data['on_demand'] as int?) ?? 0) == 1,
        ),
    ];
  }

  Future<int> heldBytes() async => (await _one('SELECT COALESCE(SUM(size), 0) AS b FROM held')).data['b'] as int;

  static final String _unselected = _unselectedOver('h', 'w', 'a');

  /// Everything the storage overview shows, in one query so the figures add up.
  Future<OfflineStorage> storage() async {
    final thumbnail = OfflineVariant.thumbnail.bit;
    final thumbnailVariant = OfflineVariant.thumbnail.index;
    final preview = OfflineVariant.preview.index;
    final original = OfflineVariant.original.index;
    final video = OfflineVariant.video.index;

    final row = await _one('''
      WITH file AS (
        SELECT h.asset_id AS asset_id,
               h.variant   AS variant,
               h.size      AS size,
               CASE WHEN ($_unselected) THEN 0 ELSE 1 END AS kept
        $_reclaimFrom
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
        COALESCE(SUM(CASE WHEN f.kept = 1 AND f.variant = $preview THEN f.size END), 0) AS kept_preview,
        COALESCE(SUM(CASE WHEN f.kept = 1 AND f.variant = $thumbnailVariant THEN f.size END), 0) AS kept_thumbnail,
        COALESCE(SUM(CASE WHEN f.kept = 0 AND f.variant = $original THEN f.size END), 0) AS cached_original,
        COALESCE(SUM(CASE WHEN f.kept = 0 AND f.variant = $video THEN f.size END), 0) AS cached_video,
        COALESCE(SUM(CASE WHEN f.kept = 0 AND f.variant = $preview THEN f.size END), 0) AS cached_preview,
        COALESCE(SUM(CASE WHEN f.kept = 0 AND f.variant = $thumbnailVariant THEN f.size END), 0) AS cached_thumbnail,
        -- An item with a thumbnail shows offline. Files kept under their own name (faces) are no item.
        COUNT(DISTINCT CASE WHEN (a.mask & $thumbnail) <> 0
                             AND EXISTS (SELECT 1 FROM main.remote_asset_entity r WHERE r.id = a.asset_id)
                            THEN a.asset_id END) AS available_assets
      FROM file f JOIN asset a ON a.asset_id = f.asset_id
    ''');

    return OfflineStorage(
      keptOriginalBytes: row.data['kept_original'] as int,
      keptVideoBytes: row.data['kept_video'] as int,
      keptPreviewBytes: row.data['kept_preview'] as int,
      keptThumbnailBytes: row.data['kept_thumbnail'] as int,
      cachedOriginalBytes: row.data['cached_original'] as int,
      cachedVideoBytes: row.data['cached_video'] as int,
      cachedPreviewBytes: row.data['cached_preview'] as int,
      cachedThumbnailBytes: row.data['cached_thumbnail'] as int,
      availableAssets: row.data['available_assets'] as int,
    );
  }

  /// What "free up space" would do, each item counted once by what it is left with.
  Future<OfflineReclaimPlan> reclaimPlan({
    Iterable<String>? assetIds,
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) async {
    final thumbnail = OfflineVariant.thumbnail.index;
    final preview = OfflineVariant.preview.index;
    final original = OfflineVariant.original.index;
    final video = OfflineVariant.video.index;
    final image = AssetType.image.index;

    // Each item is classified by what stays on disk, since it need not have held every smaller file. Files kept under
    // their own name (faces) count in bytes but are no item.
    String query(String scope) =>
        """
        WITH going AS (
          SELECT h.name AS name, h.asset_id AS asset_id, h.variant AS variant, h.size AS size,
                 COALESCE(w.on_demand, 0) AS on_demand, a.type AS type, a.id IS NOT NULL AS is_item
          $_reclaimFrom WHERE ${what.sql} $scope
        ),
        item AS (
          SELECT g.asset_id AS asset_id,
                 MAX(g.variant = $original) AS o,
                 MAX(g.variant = $video) AS v,
                 EXISTS (SELECT 1 FROM held k WHERE k.asset_id = g.asset_id AND k.variant = $thumbnail
                         AND k.name NOT IN (SELECT name FROM going)) AS keeps_t,
                 EXISTS (SELECT 1 FROM held k WHERE k.asset_id = g.asset_id AND k.variant = $preview
                         AND k.name NOT IN (SELECT name FROM going)) AS keeps_p,
                 EXISTS (SELECT 1 FROM held k WHERE k.asset_id = g.asset_id AND k.variant IN ($original, $video)
                         AND k.name NOT IN (SELECT name FROM going)) AS keeps_full
          FROM going g WHERE g.is_item GROUP BY g.asset_id
        )
        SELECT
          COUNT(*) AS files,
          COALESCE(SUM(size), 0) AS bytes,
          COUNT(DISTINCT asset_id) AS assets,
          (SELECT COUNT(*) FROM item WHERE NOT (keeps_t OR keeps_p OR keeps_full)) AS removed_items,
          (SELECT COUNT(*) FROM item WHERE keeps_t AND NOT (keeps_p OR keeps_full)) AS losing_previews,
          (SELECT COUNT(*) FROM item WHERE (keeps_p OR keeps_full) AND o = 1) AS losing_originals,
          (SELECT COUNT(*) FROM item WHERE (keeps_p OR keeps_full) AND o = 0 AND v = 1) AS losing_videos,
          -- The hand-saved share, by media type.
          COUNT(DISTINCT CASE WHEN on_demand = 1 AND type <> $image THEN asset_id END) AS hand_videos,
          COALESCE(SUM(CASE WHEN on_demand = 1 AND type <> $image THEN size END), 0) AS hand_video_bytes,
          COUNT(DISTINCT CASE WHEN on_demand = 1 AND type = $image THEN asset_id END) AS hand_photos,
          COALESCE(SUM(CASE WHEN on_demand = 1 AND type = $image THEN size END), 0) AS hand_photo_bytes
        FROM going
        """;

    if (assetIds == null) {
      return _planOf(await _one(query('')));
    }

    var plan = OfflineReclaimPlan.empty;
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      plan += _planOf(await _one(query('AND h.asset_id IN ($placeholders)'), chunk));
    }
    return plan;
  }

  /// Held files, what selects them and their asset. Not filtered to storable assets, so a trashed asset's copies are
  /// still counted, as spares.
  static const _reclaimFrom =
      'FROM held h '
      'LEFT JOIN wanted w ON w.asset_id = h.asset_id AND w.quality > 0 '
      'LEFT JOIN main.remote_asset_entity a ON a.id = h.asset_id';

  OfflineReclaimPlan _planOf(QueryRow row) => OfflineReclaimPlan(
    files: row.data['files']! as int,
    bytes: row.data['bytes']! as int,
    assets: row.data['assets']! as int,
    removedItems: row.data['removed_items']! as int,
    losingPreviews: row.data['losing_previews']! as int,
    losingOriginals: row.data['losing_originals']! as int,
    losingVideos: row.data['losing_videos']! as int,
    handVideos: row.data['hand_videos']! as int,
    handVideoBytes: row.data['hand_video_bytes']! as int,
    handPhotos: row.data['hand_photos']! as int,
    handPhotoBytes: row.data['hand_photo_bytes']! as int,
  );

  /// What each ticked cell actually frees, which depends on the rest of the choice.
  Future<Map<OfflineReclaimCell, int>> reclaimBytesByCell(OfflineReclaim what) async {
    if (what.isEmpty) {
      return const {};
    }

    final bandCase =
        'CASE WHEN ${_ReclaimWhere.band(OfflineReclaimBand.spares, 'h', 'w', 'a')} '
        'THEN ${OfflineReclaimBand.spares.index} ELSE ${OfflineReclaimBand.maintained.index} END';
    final kindCase =
        'CASE '
        'WHEN h.variant = ${OfflineVariant.video.index} THEN ${OfflineReclaimKind.videos.index} '
        'WHEN h.variant = ${OfflineVariant.original.index} THEN ${OfflineReclaimKind.originals.index} '
        'WHEN h.variant = ${OfflineVariant.preview.index} THEN ${OfflineReclaimKind.previews.index} '
        'ELSE ${OfflineReclaimKind.thumbnails.index} END';

    final rows = await _all(
      'SELECT $bandCase AS band, $kindCase AS kind, COALESCE(SUM(h.size), 0) AS bytes '
      '$_reclaimFrom WHERE ${what.sql} GROUP BY band, kind',
    );
    return {
      for (final row in rows)
        (OfflineReclaimBand.values[row.data['band'] as int], OfflineReclaimKind.values[row.data['kind'] as int]):
            row.data['bytes'] as int,
    };
  }

  Future<Map<String, int>> reclaimableBytesByAsset() async {
    final rows = await _all(
      'SELECT h.asset_id AS asset_id, SUM(h.size) AS bytes '
      '$_reclaimFrom '
      'WHERE $_unselected GROUP BY h.asset_id',
    );
    return {for (final row in rows) row.data['asset_id'] as String: row.data['bytes'] as int};
  }

  /// The reclaimable files among [assetIds]. Unpaged: bounded by the album.
  Future<List<OfflineHeldRow>> reclaimableFilesFor(
    Iterable<String> assetIds, {
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) async {
    final result = <OfflineHeldRow>[];
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _all(
        'SELECT h.name AS name, h.asset_id AS asset_id, h.variant AS variant, h.token AS token, h.size AS size '
        '$_reclaimFrom '
        'WHERE ${what.sql} AND h.asset_id IN ($placeholders)',
        chunk,
      );
      result.addAll(rows.map(_heldRow));
    }
    return result;
  }

  static OfflineHeldRow _heldRow(QueryRow row) => OfflineHeldRow(
    name: row.data['name'] as String,
    assetId: row.data['asset_id'] as String,
    variant: OfflineVariant.values[row.data['variant'] as int],
    token: row.data['token'] as int,
    size: row.data['size'] as int,
  );

  Future<List<OfflineHeldRow>> heldPage({required int limit, String? afterName}) async {
    final rows = await _all(
      'SELECT name, asset_id, variant, token, size FROM held WHERE name > ? ORDER BY name LIMIT ?',
      [afterName ?? '', limit],
    );
    return [for (final row in rows) _heldRow(row)];
  }

  Future<List<OfflineHeldRow>> reclaimableFiles({
    required int limit,
    String? afterName,
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) async {
    final rows = await _all(
      'SELECT h.name AS name, h.asset_id AS asset_id, h.variant AS variant, h.token AS token, h.size AS size '
      '$_reclaimFrom '
      'WHERE ${what.sql} AND h.name > ? ORDER BY h.name LIMIT ?',
      [afterName ?? '', limit],
    );
    return [for (final row in rows) _heldRow(row)];
  }

  /// Spare files of the least recently used items, enough to free [bytes]. Whole items at a time, oldest first, using
  /// the same spare predicate as "free up space". Items with *Save offline* pending are skipped, or a large save would
  /// evict its own first files.
  Future<List<OfflineHeldRow>> evictionCandidates({required int bytes}) async {
    final rows = await _all(
      '''
      WITH spare AS (
        SELECT h.name AS name, h.asset_id AS asset_id, h.variant AS variant, h.token AS token, h.size AS size,
               h.used_at AS used_at
        $_reclaimFrom
        WHERE ($_unselected)
          AND NOT EXISTS (SELECT 1 FROM wanted p WHERE p.asset_id = h.asset_id AND p.pinned = 1)
      ),
      item AS (
        SELECT asset_id, MAX(used_at) AS last_used, SUM(size) AS size FROM spare GROUP BY asset_id
      ),
      oldest AS (
        SELECT asset_id, last_used,
               SUM(size) OVER (ORDER BY last_used, asset_id ROWS UNBOUNDED PRECEDING) - size AS before
        FROM item
      )
      SELECT s.name AS name, s.asset_id AS asset_id, s.variant AS variant, s.token AS token, s.size AS size
      FROM spare s JOIN oldest o ON o.asset_id = s.asset_id
      WHERE o.before < ?
      ORDER BY o.last_used, s.asset_id
      ''',
      [bytes],
    );
    return [for (final row in rows) _heldRow(row)];
  }

  Future<void> touchHeld(Iterable<String> names, DateTime at) async {
    final seconds = at.millisecondsSinceEpoch ~/ 1000;
    for (final chunk in _chunked(names.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _exec('UPDATE held SET used_at = ? WHERE name IN ($placeholders)', [seconds, ...chunk]);
    }
  }

  Future<void> touchAssets(Iterable<String> assetIds, DateTime at) async {
    final seconds = at.millisecondsSinceEpoch ~/ 1000;
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _exec('UPDATE held SET used_at = ? WHERE asset_id IN ($placeholders)', [seconds, ...chunk]);
    }
  }

  Future<void> dropFetchedWithoutFiles() async {
    await _exec(
      'DELETE FROM wanted WHERE on_demand = 1 '
      'AND asset_id NOT IN (SELECT DISTINCT asset_id FROM held)',
    );
    revision++;
  }

  Future<void> forget(Iterable<String> assetIds) async {
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _exec('DELETE FROM wanted WHERE asset_id IN ($placeholders)', chunk);
    }
    revision++;
  }

  /// Assets saved by hand and not yet complete, which the queue puts first.
  Future<Set<String>> errands() async {
    final rows = await _all('SELECT asset_id FROM wanted WHERE pinned = 1');
    return {for (final row in rows) row.data['asset_id'] as String};
  }

  Future<void> addErrands(Iterable<String> assetIds) async {
    final ids = assetIds.toList();
    if (ids.isEmpty) {
      return;
    }
    await _execEach('UPDATE wanted SET pinned = 1 WHERE asset_id = ?', [
      for (final id in ids) [id],
    ]);
    revision++;
  }

  /// Drops the mark for an errand that arrived or was taken back. Files are untouched.
  Future<void> dropErrands(Iterable<String> assetIds) async {
    final ids = assetIds.toList();
    if (ids.isEmpty) {
      return;
    }
    for (final chunk in _chunked(ids)) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _exec('UPDATE wanted SET pinned = 0 WHERE asset_id IN ($placeholders)', chunk);
    }
    revision++;
  }

  static final String _storable = offlineStorableSql('a');

  /// Re-derives every decision from the selection in one statement: [OfflinePolicy.resolve] in SQL. An exclusion
  /// anywhere wins, otherwise the best of the library rung and every album naming the item. The tests check the two
  /// agree.
  ///
  /// While upstream is not complete its tables may be half-synced (assets without their albums), so the derive only
  /// adds and raises decisions: nothing is lowered, demoted or dropped until a full sync has finished.
  Future<int> derive(OfflinePolicy policy, DateTime touchedAt) async {
    var moved = 0;
    await _db.transaction(() async {
      await _exec('DROP TABLE IF EXISTS temp.album_rung');
      await _exec('CREATE TEMP TABLE album_rung (album_id TEXT PRIMARY KEY, quality INTEGER NOT NULL)');
      await _execEach('INSERT OR REPLACE INTO temp.album_rung (album_id, quality) VALUES (?, ?)', [
        for (final entry in policy.albums.entries)
          if (entry.value.isWanted) [entry.key, entry.value.code],
        for (final id in policy.excluded) [id, 0],
      ]);

      await _exec('''
        DROP TABLE IF EXISTS temp.selected
      ''');
      await _exec(
        '''
        CREATE TEMP TABLE selected AS
        SELECT asset_id,
               CASE WHEN excluded = 1 THEN 0 ELSE MAX(best, ?) END AS quality,
               created_at
        FROM (
          SELECT a.id AS asset_id,
                 MAX(CASE WHEN r.quality = 0 THEN 1 ELSE 0 END) AS excluded,
                 COALESCE(MAX(CASE WHEN r.quality > 0 THEN r.quality END), 0) AS best,
                 unixepoch(a.created_at) * 1000 AS created_at
          FROM main.remote_asset_entity a
          LEFT JOIN main.remote_album_asset_entity l ON l.asset_id = a.id
          LEFT JOIN temp.album_rung r ON r.album_id = l.album_id
          WHERE $_storable
          GROUP BY a.id
        )
        WHERE quality > 0
      ''',
        [policy.library?.code ?? 0],
      );
      // After reading upstream's tables, and the transaction's first read of this file (see [vouch]).
      final complete = await _isUpstreamComplete();

      // Only rows whose decision moved are stamped, so re-deriving does not re-order the whole queue. A hand-fetched row
      // a selection now covers becomes the selection's. Half-synced, only raises count.
      final moves = complete
          ? 'WHERE wanted.quality <> excluded.quality OR wanted.on_demand <> excluded.on_demand'
          : 'WHERE excluded.quality > wanted.quality';
      await _exec(
        'INSERT INTO wanted (asset_id, quality, created_at, on_demand, touched_at) '
        'SELECT asset_id, quality, created_at, 0, ? FROM temp.selected '
        // `WHERE true` lets SQLite tell the upsert's ON apart from a join's.
        'WHERE true '
        'ON CONFLICT(asset_id) DO UPDATE SET '
        'quality = excluded.quality, created_at = excluded.created_at, '
        'on_demand = excluded.on_demand, touched_at = excluded.touched_at '
        '$moves',
        [touchedAt.millisecondsSinceEpoch ~/ 1000],
      );
      moved += (await _one('SELECT changes() AS n')).data['n'] as int;

      if (complete) {
        // An errand still pending outlives the selection that covered it: it goes back to being hand-fetched.
        await _exec(
          'UPDATE wanted SET on_demand = 1, quality = ? '
          'WHERE on_demand = 0 AND pinned = 1 AND asset_id NOT IN (SELECT asset_id FROM temp.selected) '
          'AND asset_id IN (SELECT a.id FROM main.remote_asset_entity a WHERE $_storable)',
          [kOfflineErrandQuality.code],
        );
        moved += (await _one('SELECT changes() AS n')).data['n'] as int;

        // What the selection no longer covers. Hand-fetched rows stay until "free up space" takes them.
        await _exec('DELETE FROM wanted WHERE on_demand = 0 AND asset_id NOT IN (SELECT asset_id FROM temp.selected)');
        moved += (await _one('SELECT changes() AS n')).data['n'] as int;
      }

      await _exec('DROP TABLE temp.selected');
      await _exec('DROP TABLE temp.album_rung');
    });
    if (moved > 0) {
      revision++;
    }
    return moved;
  }

  Future<void> set(Iterable<OfflineFlagRow> assets) async {
    final rows = [
      for (final row in assets)
        [
          row.id,
          row.quality.code,
          row.createdAt.millisecondsSinceEpoch,
          row.onDemand ? 1 : 0,
          row.touchedAt.millisecondsSinceEpoch ~/ 1000,
        ],
    ];
    if (rows.isEmpty) {
      return;
    }
    // An upsert rather than `INSERT OR REPLACE`, which would reset columns not listed.
    await _execEach(
      'INSERT INTO wanted (asset_id, quality, created_at, on_demand, touched_at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(asset_id) DO UPDATE SET '
      'quality = excluded.quality, created_at = excluded.created_at, '
      'on_demand = excluded.on_demand, touched_at = excluded.touched_at',
      rows,
    );
    revision++;
  }

  /// Records arrived files, at most one per asset and variant; arriving counts as being used. A thumbnail or preview of
  /// the current version also replaces the other one's older version, which the image path will never ask for again:
  /// the two share the thumbhash, so the index keeps one token for both. Only of the current version, as upstream's
  /// thumbhash says: a download queued before an edit can land after the new version, and must not take it away.
  /// Returns the older files this replaced and their sizes, for the caller to delete and stop counting.
  Future<List<({String name, int size})>> markHeld(Iterable<OfflineHeldRow> files, {DateTime? at}) async {
    final held = files.toList();
    if (held.isEmpty) {
      return const [];
    }
    final usedAt = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final current = await _currentVersionTokens({
      for (final file in held)
        if (file.variant == OfflineVariant.thumbnail || file.variant == OfflineVariant.preview) file.assetId,
    });
    final shared = '${OfflineVariant.thumbnail.index},${OfflineVariant.preview.index}';
    const replaced = 'asset_id = ? AND name <> ? AND (variant = ? OR (? AND variant IN (';
    final superseded = <String, int>{};
    await _db.transaction(() async {
      // In order, so of two versions in one batch the later one stays.
      for (final file in held) {
        final args = [
          file.assetId,
          file.name,
          file.variant.index,
          current[file.assetId] == file.token ? 1 : 0,
          file.token,
        ];
        final where = '$replaced$shared) AND token <> ?))';
        for (final row in await _all('SELECT name, size FROM held WHERE $where', args)) {
          superseded[row.data['name'] as String] = row.data['size'] as int;
        }
        await _exec('DELETE FROM held WHERE $where', args);
        await _exec(
          'INSERT OR REPLACE INTO held (name, asset_id, variant, token, size, used_at) VALUES (?, ?, ?, ?, ?, ?)',
          [file.name, file.assetId, file.variant.index, file.token, file.size, usedAt],
        );
        superseded.remove(file.name);
      }
    });
    return [for (final MapEntry(key: name, value: size) in superseded.entries) (name: name, size: size)];
  }

  /// The token of each asset's current thumbnail and preview, from upstream's thumbhash. An asset upstream does not
  /// have, or has no thumbhash for, is left out: nothing then counts as its current version.
  Future<Map<String, int>> _currentVersionTokens(Set<String> assetIds) async {
    if (assetIds.isEmpty) {
      return const {};
    }
    final tokens = <String, int>{};
    for (final chunk in _chunked(assetIds.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _all(
        "SELECT id, thumb_hash FROM main.remote_asset_entity WHERE id IN ($placeholders) AND thumb_hash <> ''",
        chunk,
      );
      for (final row in rows) {
        final id = row.data['id'] as String;
        tokens[id] = offlineVersionToken(id, row.data['thumb_hash'] as String);
      }
    }
    return tokens;
  }

  /// Every held file of an item in the locked folder, whether recorded under the item or under its own name. Those
  /// bytes must not sit outside the PIN gate. Being locked is something upstream says, not something missing, so this
  /// needs no complete upstream.
  Future<List<OfflineHeldRow>> heldOfLocked() async {
    const columns = 'h.name AS name, h.asset_id AS asset_id, h.variant AS variant, h.token AS token, h.size AS size';
    final rows = await _all(
      'SELECT $columns FROM main.remote_asset_entity a JOIN held h ON h.asset_id = a.id WHERE a.visibility = ? '
      'UNION '
      // A file kept under its own name, `assets_<id>_…`: a range of the primary key per locked item.
      "SELECT $columns FROM main.remote_asset_entity a JOIN held h "
      "ON h.name >= 'assets_' || a.id || '_' AND h.name < 'assets_' || a.id || '`' AND h.asset_id = h.name "
      'WHERE a.visibility = ?',
      [AssetVisibility.locked.index, AssetVisibility.locked.index],
    );
    return [for (final row in rows) _heldRow(row)];
  }

  Future<void> dropHeld(Iterable<String> names) async {
    for (final chunk in _chunked(names.toList())) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _exec('DELETE FROM held WHERE name IN ($placeholders)', chunk);
    }
  }

  Future<void> clearHeld() => _exec('DELETE FROM held');

  /// Forgets the mirror entirely, for when the selection is abandoned.
  Future<void> clearAll() async {
    await _db.transaction(() async {
      for (final table in const ['wanted', 'held', 'failures']) {
        await _exec('DELETE FROM $table');
      }
      // The readiness mark and the reset count describe upstream's tables, not the mirror. The schema version is in the
      // file's header.
      await _exec('DELETE FROM meta WHERE key NOT IN (?, ?)', [_upstreamCompleteKey, _resetGenerationKey]);
    });
    revision++;
  }

  static const _maxAttempts = 3;

  Future<void> recordFailure(String name) => _exec(
    'INSERT INTO failures (name, attempts) VALUES (?, 1) ON CONFLICT(name) DO UPDATE SET attempts = attempts + 1',
    [name],
  );

  Future<void> clearFailure(String name) => _exec('DELETE FROM failures WHERE name = ?', [name]);

  Future<Set<String>> abandoned() async => {
    for (final row in await _all('SELECT name FROM failures WHERE attempts >= ?', [_maxAttempts]))
      row.data['name'] as String,
  };

  Future<int> abandonedCount() async =>
      (await _one('SELECT COUNT(*) AS c FROM failures WHERE attempts >= ?', [_maxAttempts])).data['c'] as int;

  Future<void> forgetFailures() async {
    await _exec('DELETE FROM failures');
    revision++;
  }

  Future<String?> _meta(String key) async {
    final row = await _oneOrNull('SELECT value FROM meta WHERE key = ?', [key]);
    return row == null ? null : row.data['value'] as String;
  }

  Future<void> _setMeta(String key, String? value) async {
    if (value == null) {
      await _exec('DELETE FROM meta WHERE key = ?', [key]);
      return;
    }
    await _exec('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [key, value]);
  }

  Future<DateTime?> lastReclaim() async {
    final millis = int.tryParse(await _meta('last_reclaim') ?? '');
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> setReclaimed(DateTime at) async {
    await _setMeta('last_reclaim', at.millisecondsSinceEpoch.toString());
    await _setMeta('reclaim_pending', null);
  }

  /// Whether a walk was deferred, so the next launch retries rather than waiting a week.
  Future<bool> reclaimPending() async => await _meta('reclaim_pending') != null;

  Future<void> setReclaimPending() => _setMeta('reclaim_pending', '1');

  /// Runs [reads] over upstream's tables, then reads the readiness mark: whether a foreground remote sync has finished
  /// since the tables were last wiped. This is the only way to read the mark, and it is always read last. A reset
  /// clears it before wiping, so a mark still set after [reads] means they saw whole tables; read any earlier, a reset
  /// landing in between would pass for a library emptied on the server.
  ///
  /// Whatever treats an asset or album missing upstream as gone takes it from [OfflineVouched.ifComplete], which is
  /// null until upstream is complete. Inside one statement, as in [_unselectedOver] and [derive], SQL gets the same
  /// guarantee from reading the mark in the same statement or transaction, after the rows.
  Future<OfflineVouched<T>> vouch<T>(Future<T> Function() reads) async {
    final value = await reads();
    return OfflineVouched._(value, complete: await _isUpstreamComplete());
  }

  Future<bool> _isUpstreamComplete() async => await _meta(_upstreamCompleteKey) != null;

  /// How many upstream resets this file has seen. Read when a remote sync starts and handed to [setUpstreamComplete]
  /// when it finishes.
  Future<int> resetGeneration() async => int.tryParse(await _meta(_resetGenerationKey) ?? '') ?? 0;

  /// Records a finished remote sync. Returns whether this opened the gate.
  ///
  /// With [ifGeneration], the [resetGeneration] read when the sync started, the mark is only set if no reset came
  /// since, checked in the same statement that sets it: a reset landing after the sync finished but before this write
  /// would otherwise pass an emptied library for a complete one. A reset during the sync also leaves it unset, until
  /// the next sync.
  Future<bool> setUpstreamComplete({int? ifGeneration}) async {
    if (await _isUpstreamComplete()) {
      return false;
    }
    if (ifGeneration == null) {
      await _setMeta(_upstreamCompleteKey, '1');
      return true;
    }
    await _exec(
      "INSERT OR IGNORE INTO meta (key, value) SELECT ?, '1' "
      'WHERE COALESCE((SELECT CAST(value AS INTEGER) FROM meta WHERE key = ?), 0) = ?',
      [_upstreamCompleteKey, _resetGenerationKey, ifGeneration],
    );
    return _isUpstreamComplete();
  }

  /// Called by upstream's `SyncStreamRepository.reset()` before it wipes the remote tables, on sign-out and on a
  /// server-requested reset, from whichever isolate runs it. A no-op on a connection without the fork's schema. Never
  /// throws, so the mirror cannot stop a sign-out: a file that cannot take this write cannot take the mirror's deletes
  /// either.
  static Future<void> noteUpstreamReset(Drift db) async {
    try {
      final attached = await db
          .customSelect(
            'SELECT 1 FROM pragma_database_list WHERE name = ?',
            variables: [const Variable(kOfflineSchema)],
          )
          .getSingleOrNull();
      if (attached == null) {
        return;
      }
      final hasMeta = await db
          .customSelect("SELECT 1 FROM $kOfflineSchema.sqlite_master WHERE type = 'table' AND name = 'meta'")
          .getSingleOrNull();
      if (hasMeta == null) {
        return;
      }
      await db.transaction(() async {
        await db.customStatement(
          'INSERT INTO $kOfflineSchema.meta (key, value) VALUES (?, 1) '
          'ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1',
          [_resetGenerationKey],
        );
        await db.customStatement('DELETE FROM $kOfflineSchema.meta WHERE key = ?', [_upstreamCompleteKey]);
      });
    } catch (error, stackTrace) {
      Logger(
        'OfflineFlagsRepository',
      ).severe('Could not mark upstream incomplete; resetting anyway', error, stackTrace);
    }
  }

  /// Whether the files stored under the server's path prefix have been renamed (see `offlineUnprefixStore`).
  Future<bool> storeUnprefixed() async => await _meta('store_unprefixed') != null;

  Future<void> setStoreUnprefixed() => _setMeta('store_unprefixed', '1');

  /// Which video the store was filled with, `original` or `video/playback`.
  Future<String?> videoForm() => _meta('video_form');

  Future<void> setVideoForm(String value) => _setMeta('video_form', value);

  Iterable<List<String>> _chunked(List<String> ids) sync* {
    for (var i = 0; i < ids.length; i += 500) {
      yield ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
    }
  }
}

/// Upstream gained a table named like one of the fork's, which would silently shadow it.
class OfflineSchemaClash extends StateError {
  OfflineSchemaClash(super.message);
}

/// Something read from upstream's tables, and whether they were complete when it was read (see
/// [OfflineFlagsRepository.vouch], the only place one is made).
final class OfflineVouched<T> {
  const OfflineVouched._(this._value, {required this.complete});

  final T _value;

  /// Whether upstream's tables were whole. Enough for decisions that delete nothing, such as whether a pass may settle.
  final bool complete;

  /// The value, only when upstream was complete: what a decision to forget or delete must be taken from.
  T? get ifComplete => complete ? _value : null;
}
