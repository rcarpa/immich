/// immich-sync fork: the integrity pass, the only thing that walks the whole store and deletes files nothing accounts
/// for.
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

  /// Files not deleted because too much of the store looked unaccounted for.
  final int refused;

  /// Counted rather than logged, since the isolate has no log listener: files that could not be read, and deletions
  /// that failed.
  final int unreadable;
  final int failed;
}

/// The largest share of the store one unprompted pass may delete before assuming the fault is its own: a half-synced
/// asset table looks like a library half deleted on the server.
const _maxShareRemovable = 0.25;

/// Walks `pinned/`, deletes what [wantedHashes] does not vouch for, and rewrites `held` to match what is there. Files
/// modified since [startedAt] are kept: browsing and downloads write while the pass runs, and record what they wrote
/// only later. [confirmed] lifts the share cap, for a reduction a complete sync has since borne out.
Future<OfflineReclaimResult> offlineReclaimStore({
  required String databasePath,
  required String pinnedRoot,
  required Int64List wantedHashes,
  required DateTime startedAt,
  bool expected = false,
  bool confirmed = false,
}) {
  // A second early, for file systems that keep modification times to the second.
  final keepSince = startedAt.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch;
  return Isolate.run(() => _reclaim(databasePath, pinnedRoot, wantedHashes, keepSince, expected, confirmed));
}

OfflineReclaimResult _reclaim(
  String databasePath,
  String pinnedRoot,
  Int64List wantedHashes,
  int keepSince,
  bool expected,
  bool confirmed,
) {
  final wanted = HashSet<int>.of(wantedHashes);
  final root = Directory(pinnedRoot);
  if (!root.existsSync()) {
    return const OfflineReclaimResult(removed: 0);
  }

  final db = sqlite3.open(databasePath);
  // A second connection to the app's database; wait rather than fail on a collision.
  db.execute('PRAGMA busy_timeout = 10000');

  var removed = 0;
  var refused = 0;
  var unreadable = 0;
  var failed = 0;

  try {
    // Every file is listed first, so the decision to delete is taken against the whole picture.
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
      // Bucket by bucket rather than one recursive listing of the whole store.
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
            final stat = entity.statSync();
            if (stat.type == FileSystemEntityType.notFound) {
              throw FileSystemException('Gone', entity.path);
            }
            // An empty file is what an interrupted write leaves; dropped, it is fetched again if wanted.
            final keep =
                stat.size > 0 &&
                (wanted.contains(offlineNameHash(name)) || stat.modified.millisecondsSinceEpoch >= keepSince);
            insert.execute([name, entity.path, stat.size, keep ? 1 : 0]);
          } catch (_) {
            // Gone since it was listed. Its `held` row is dropped below and the file fetched again if wanted.
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
    // A changed video form is the one instructed reduction, so its videos (`.mp4`) are exempt from the cap, and nothing
    // else is.
    final capped = expected
        ? db.select("SELECT COUNT(*) AS c FROM present WHERE wanted = 0 AND name NOT LIKE '%.mp4'").first['c'] as int
        : doomed;

    if (!confirmed && total > 0 && capped > total * _maxShareRemovable) {
      // Nothing is deleted, but the rows are still corrected to what exists.
      refused = doomed;
    } else {
      for (final row in db.select('SELECT path FROM present WHERE wanted = 0')) {
        try {
          File(row['path'] as String).deleteSync();
          removed++;
        } catch (_) {
          failed++;
        }
      }
      db.execute('DELETE FROM present WHERE wanted = 0');
    }

    // A row for a file that is gone would stop the reconciler fetching it again.
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

/// Renames files stored under the server's path prefix to the names they have now (see `offlineUnprefixedName`), and
/// their `held` rows with them, so a server behind a subpath keeps its copies. A file whose new name is already there
/// is deleted. Returns how many files moved or went.
Future<int> offlineUnprefixStore({required String databasePath, required String pinnedRoot}) => Isolate.run(() {
  final root = Directory(pinnedRoot);
  if (!root.existsSync()) {
    return 0;
  }
  final moves = <(String, String)>[];
  for (final bucket in root.listSync(followLinks: false).whereType<Directory>()) {
    for (final file in bucket.listSync(followLinks: false).whereType<File>()) {
      final name = p.basename(file.path);
      final renamed = offlineUnprefixedName(name);
      if (renamed == null) {
        continue;
      }
      final target = File(p.join(pinnedRoot, offlineBlobBucket(renamed), renamed));
      try {
        if (target.existsSync()) {
          file.deleteSync();
        } else {
          target.parent.createSync(recursive: true);
          file.renameSync(target.path);
        }
        moves.add((name, renamed));
      } catch (_) {
        // Left as it is; the integrity pass sweeps it, and the file is fetched again if wanted.
      }
    }
  }
  if (moves.isEmpty) {
    return 0;
  }

  final db = sqlite3.open(databasePath);
  try {
    db.execute('PRAGMA busy_timeout = 10000');
    // A file kept under its own name now names its asset, so its row is keyed and typed by the new name.
    final update = db.prepare(
      'UPDATE OR REPLACE held SET name = ?, '
      'asset_id = CASE WHEN asset_id = name THEN ? ELSE asset_id END, '
      'variant = CASE WHEN asset_id = name THEN ? ELSE variant END '
      'WHERE name = ?',
    );
    db.execute('BEGIN');
    try {
      for (final (from, to) in moves) {
        update.execute([to, to, offlineVariantOfName(to).index, from]);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    } finally {
      update.close();
    }
  } finally {
    db.close();
  }
  return moves.length;
});

/// Deletes the paths it can, ignoring ones already gone, and counts the failures.
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
