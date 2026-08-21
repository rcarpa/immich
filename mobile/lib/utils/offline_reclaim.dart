/// immich-sync fork — the integrity pass (FORK.md §3.3). The only thing that walks the whole store, and so the only
/// thing that can delete a file nobody asked about.
library;

import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// What the pass did.
class OfflineReclaimResult {
  const OfflineReclaimResult({required this.removed, this.refused = 0, this.unreadable = 0, this.failed = 0});

  final int removed;

  /// Files this pass declined to delete because too much of the store was unaccounted for.
  final int refused;

  /// Counted rather than logged, because this runs on its own isolate where the log listener is not. Both say the store
  /// is not what it claims: files that could not be read at all, and deletions that did not take.
  final int unreadable;
  final int failed;
}

/// The largest share of the store, by file count, that one unprompted pass may delete before it stops and assumes the
/// fault is its own: a half-repopulated asset table looks exactly like a library half deleted on the server.
const _maxShareRemovable = 0.25;

/// Walks `pinned/`, deletes what [wantedHashes] does not vouch for, and rewrites `held` to match what is actually
/// there.
Future<OfflineReclaimResult> offlineReclaimStore({
  required String databasePath,
  required String pinnedRoot,
  required Int64List wantedHashes,
  bool expected = false,
}) => Isolate.run(() => _reclaim(databasePath, pinnedRoot, wantedHashes, expected));

OfflineReclaimResult _reclaim(
  String databasePath,
  String pinnedRoot,
  Int64List wantedHashes,
  bool expected,
) {
  final wanted = HashSet<int>.of(wantedHashes);
  final root = Directory(pinnedRoot);
  if (!root.existsSync()) {
    return const OfflineReclaimResult(removed: 0);
  }

  final db = sqlite3.open(databasePath);
  // A second connection to a database the app also has open. WAL lets both
  // proceed; this is how long to wait rather than fail if they collide.
  db.execute('PRAGMA busy_timeout = 10000');

  var removed = 0;
  var refused = 0;
  var unreadable = 0;
  var failed = 0;

  try {
    // Every file is written down first, wanted or not, so the decision to delete is taken once against the whole
    // picture rather than file by file.
    db.execute('''
      CREATE TEMP TABLE present (
        name   TEXT PRIMARY KEY,
        path   TEXT NOT NULL,
        size   INTEGER NOT NULL,
        wanted INTEGER NOT NULL
      )
    ''');
    final insert = db.prepare('INSERT OR REPLACE INTO present (name, path, size, wanted) VALUES (?, ?, ?, ?)');

    try {
      // Bucket by bucket: a recursive listing materialises every entry in the
      // store before the first one is examined.
      for (final bucket in root.listSync(followLinks: false)) {
        if (bucket is! Directory) {
          continue;
        }
        db.execute('BEGIN');
        for (final entity in bucket.listSync(followLinks: false)) {
          if (entity is! File) {
            continue;
          }
          final name = p.basename(entity.path);
          try {
            insert.execute([
              name,
              entity.path,
              entity.statSync().size,
              wanted.contains(offlineNameHash(name)) ? 1 : 0,
            ]);
          } catch (_) {
            // Listed a moment ago, un-`stat`able now: it has just gone. Skipping is also the right answer — absent from
            // `present`, its `held` row is dropped below and the reconciler fetches it again if wanted.
            unreadable++;
            continue;
          }
        }
        db.execute('COMMIT');
      }
    } finally {
      insert.close();
    }

    final total = db.select('SELECT COUNT(*) AS c FROM present').first['c'] as int;
    final doomed = db.select('SELECT COUNT(*) AS c FROM present WHERE wanted = 0').first['c'] as int;

    if (!expected && total > 0 && doomed > total * _maxShareRemovable) {
      // Nothing is deleted, but the rows describing what is here are still corrected: a pass that cannot trust the
      // question can still trust its own eyes about what exists.
      refused = doomed;
    } else {
      for (final row in db.select('SELECT path FROM present WHERE wanted = 0')) {
        try {
          File(row['path'] as String).deleteSync();
          removed++;
        } catch (_) {
          // Left for the next pass rather than failing the whole walk.
          failed++;
        }
      }
      db.execute('DELETE FROM present WHERE wanted = 0');
    }

    // A row describing a file that is gone would keep the reconciler from ever fetching it again.
    db.execute('DELETE FROM held WHERE name NOT IN (SELECT name FROM present)');
    db.execute(
      'UPDATE held SET size = (SELECT size FROM present WHERE present.name = held.name) '
      'WHERE size <> (SELECT size FROM present WHERE present.name = held.name)',
    );
  } finally {
    db.close();
  }

  return OfflineReclaimResult(removed: removed, refused: refused, unreadable: unreadable, failed: failed);
}

/// Deletes named paths, ignoring the ones already gone.
/// Deletes what it can, and says how much it could not: the caller quoted a figure to the user, and a delete that did
/// not take makes that figure a lie.
Future<({int removed, int failed})> offlineDeletePaths(List<String> paths) => Isolate.run(() {
  var removed = 0;
  var failed = 0;
  for (final path in paths) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
        removed++;
      }
    } catch (_) {
      // Left for the integrity pass rather than failing the batch.
      failed++;
    }
  }
  return (removed: removed, failed: failed);
});

/// Removes the whole store.
Future<void> offlineDeleteStore(String root) => Isolate.run(() {
  final directory = Directory(root);
  if (directory.existsSync()) {
    directory.deleteSync(recursive: true);
  }
});
