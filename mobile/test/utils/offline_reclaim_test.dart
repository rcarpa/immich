/// immich-sync fork: the integrity pass deletes files nothing accounts for, but not ones written while it runs.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:immich_mobile/utils/offline_reclaim.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory root;
  late String databasePath;

  setUp(() {
    root = Directory.systemTemp.createTempSync('offline_reclaim');
    databasePath = p.join(root.path, 'offline.db');
    sqlite3.open(databasePath)
      ..execute(
        'CREATE TABLE held (name TEXT PRIMARY KEY, asset_id TEXT, variant INTEGER, token INTEGER, size INTEGER)',
      )
      ..close();
  });

  tearDown(() => root.deleteSync(recursive: true));

  File store(String name, {required DateTime modified}) => File(offlinePinnedPath(root.path, name))
    ..createSync(recursive: true)
    ..writeAsBytesSync([1, 2, 3])
    ..setLastModifiedSync(modified);

  test('deletes an unaccounted file, but keeps one written since the pass began', () async {
    final startedAt = DateTime.now();
    final kept = [for (var i = 0; i < 4; i++) store('kept-$i', modified: startedAt.subtract(const Duration(days: 1)))];
    final stale = store('stale', modified: startedAt.subtract(const Duration(days: 1)));
    final fresh = store('fresh', modified: startedAt.add(const Duration(seconds: 1)));

    final result = await offlineReclaimStore(
      databasePath: databasePath,
      pinnedRoot: p.join(root.path, kOfflinePinnedDirectory),
      wantedHashes: Int64List.fromList([for (var i = 0; i < 4; i++) offlineNameHash('kept-$i')]),
      startedAt: startedAt,
    );

    expect(result.removed, 1);
    expect(stale.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(kept.every((file) => file.existsSync()), isTrue);
  });

  test('deletes an empty file even when it is wanted, so it is fetched again', () async {
    final startedAt = DateTime.now();
    final old = startedAt.subtract(const Duration(days: 1));
    final kept = [for (var i = 0; i < 4; i++) store('kept-$i', modified: old)];
    // What a crash between rename and flush leaves.
    final empty = store('empty', modified: old)..writeAsBytesSync(const []);
    empty.setLastModifiedSync(old);

    final result = await offlineReclaimStore(
      databasePath: databasePath,
      pinnedRoot: p.join(root.path, kOfflinePinnedDirectory),
      wantedHashes: Int64List.fromList([
        offlineNameHash('empty'),
        for (var i = 0; i < 4; i++) offlineNameHash('kept-$i'),
      ]),
      startedAt: startedAt,
    );

    expect(result.removed, 1);
    expect(empty.existsSync(), isFalse);
    expect(kept.every((file) => file.existsSync()), isTrue);
  });

  test('does not claim an empty file as stored', () async {
    final full = store('full', modified: DateTime.now());
    store('empty', modified: DateTime.now()).writeAsBytesSync(const []);

    expect(offlineAdopt(root.path, 'full'), full.lengthSync());
    expect(offlineAdopt(root.path, 'empty'), isNull);
    expect(await offlineAdoptAll(root.path, ['full', 'empty', 'absent']), {'full': 3});
  });

  test('refuses a large reduction unless a complete sync confirmed it', () async {
    final startedAt = DateTime.now();
    final old = startedAt.subtract(const Duration(days: 1));
    final kept = store('kept', modified: old);
    final stale = [for (var i = 0; i < 3; i++) store('stale-$i', modified: old)];

    Future<OfflineReclaimResult> run({required bool confirmed}) => offlineReclaimStore(
      databasePath: databasePath,
      pinnedRoot: p.join(root.path, kOfflinePinnedDirectory),
      wantedHashes: Int64List.fromList([offlineNameHash('kept')]),
      startedAt: startedAt,
      confirmed: confirmed,
    );

    final refused = await run(confirmed: false);
    expect(refused.refused, 3);
    expect(stale.every((file) => file.existsSync()), isTrue);

    final confirmed = await run(confirmed: true);
    expect(confirmed.removed, 3);
    expect(stale.any((file) => file.existsSync()), isFalse);
    expect(kept.existsSync(), isTrue);
  });

  group('a store from builds that kept the server path in names', () {
    String pinned() => p.join(root.path, kOfflinePinnedDirectory);

    void row(String name, String assetId, OfflineVariant variant) => sqlite3.open(databasePath)
      ..execute('INSERT INTO held (name, asset_id, variant, token, size) VALUES (?, ?, ?, 1, 3)', [
        name,
        assetId,
        variant.index,
      ])
      ..close();

    Map<String, (String, int)> rows() {
      final db = sqlite3.open(databasePath);
      try {
        return {
          for (final r in db.select('SELECT name, asset_id, variant FROM held'))
            r['name'] as String: (r['asset_id'] as String, r['variant'] as int),
        };
      } finally {
        db.close();
      }
    }

    test('is renamed in place, rows and all', () async {
      const old = 'immich_api_assets_x_thumbnail_preview_811c9dc5';
      const now = 'assets_x_thumbnail_preview_811c9dc5';
      final file = store(old, modified: DateTime.now());
      row(old, 'x', OfflineVariant.preview);
      // Kept by the image path under its own name, which hid that it belongs to an asset.
      const loose = 'immich_api_assets_y_thumbnail_thumbnail_811c9dc5';
      store(loose, modified: DateTime.now());
      row(loose, loose, OfflineVariant.thumbnail);
      final untouched = store('assets_z_thumbnail_811c9dc5', modified: DateTime.now());

      final moved = await offlineUnprefixStore(databasePath: databasePath, pinnedRoot: pinned());

      expect(moved, 2);
      expect(file.existsSync(), isFalse);
      expect(File(offlinePinnedPath(root.path, now)).existsSync(), isTrue);
      expect(untouched.existsSync(), isTrue);
      expect(rows(), {
        now: ('x', OfflineVariant.preview.index),
        'assets_y_thumbnail_thumbnail_811c9dc5': (
          'assets_y_thumbnail_thumbnail_811c9dc5',
          OfflineVariant.thumbnail.index,
        ),
      });
    });

    test('drops a copy whose new name is already there', () async {
      const old = 'immich_api_assets_x_original_f83372e3.mp4';
      const now = 'assets_x_original_f83372e3.mp4';
      final stale = store(old, modified: DateTime.now());
      final current = store(now, modified: DateTime.now());

      await offlineUnprefixStore(databasePath: databasePath, pinnedRoot: pinned());

      expect(stale.existsSync(), isFalse);
      expect(current.existsSync(), isTrue);
    });
  });
}
