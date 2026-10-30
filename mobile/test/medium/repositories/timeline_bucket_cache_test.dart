/// immich-sync fork — the timeline's bucket cache, and mostly the ways it is allowed to fail.
///
/// The cache exists to save twenty seconds at launch on a large library, but its actual contract is the opposite one:
/// the app must behave exactly as it did without it whenever anything at all is wrong. So most of what is here is a
/// damaged, missing or absurd row, and the expected answer to all of them is the same — a miss, and no exception.
library;

import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline_bucket_cache.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

import '../repository_context.dart';

void main() {
  // The bare-database case below builds a second `Drift` while the fixture's own is still alive. They are two separate
  // in-memory databases with no executor between them, which is the race drift is warning about not happening.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late MediumRepositoryContext ctx;
  late TimelineBucketCache sut;

  const key = 'day:owner-1';

  final buckets = <Bucket>[
    TimeBucket(date: DateTime(2026, 8, 24), assetCount: 47),
    TimeBucket(date: DateTime(2026, 8, 23), assetCount: 12),
    TimeBucket(date: DateTime(2019, 1, 1), assetCount: 3),
  ];

  Future<void> writeRow({required int format, required int bucketCount, required String payload}) =>
      ctx.db.customStatement(
        'INSERT OR REPLACE INTO $kOfflineSchema.timeline_buckets '
        '(cache_key, format, bucket_count, buckets, computed_at) VALUES (?1, ?2, ?3, ?4, ?5)',
        [key, format, bucketCount, payload, DateTime.now().toUtc().toIso8601String()],
      );

  setUp(() async {
    ctx = MediumRepositoryContext();
    await ctx.db.customStatement("ATTACH DATABASE ':memory:' AS $kOfflineSchema");
    await TimelineBucketCache.ensureSchema(ctx.db);
    sut = TimelineBucketCache(ctx.db);
  });

  tearDown(() async {
    await ctx.dispose();
  });

  test('a written list comes back exactly, dates included', () async {
    await sut.remember(key, buckets);

    final read = await sut.read(key);

    expect(read, buckets);
    // `DateTime ==` compares `isUtc` as well as the instant, so a list that merely looks right would still force a
    // rebuild against its live twin. This is the assertion that keeps the encoding honest.
    expect((read![0] as TimeBucket).date.isUtc, isFalse);
    expect((read[0] as TimeBucket).date, DateTime(2026, 8, 24));
  });

  test('a key that was never written misses', () async {
    expect(await sut.read('day:nobody'), isNull);
  });

  test('a different set of users is a different key', () async {
    await sut.remember(TimelineBucketCache.keyFor(['b', 'a'], GroupAssetsBy.day), buckets);

    expect(await sut.read(TimelineBucketCache.keyFor(['a', 'b'], GroupAssetsBy.day)), buckets);
    expect(await sut.read(TimelineBucketCache.keyFor(['a', 'b', 'c'], GroupAssetsBy.day)), isNull);
    expect(await sut.read(TimelineBucketCache.keyFor(['a', 'b'], GroupAssetsBy.month)), isNull);
  });

  test('an empty list is never stored, so a hit is always worth drawing', () async {
    await sut.remember(key, const []);

    expect(await sut.read(key), isNull);
  });

  test('an empty list deletes what an earlier, fuller library left behind', () async {
    final cache = TimelineBucketCache(ctx.db, writeEvery: Duration.zero);
    await cache.remember(key, buckets);
    expect(await cache.read(key), buckets);

    await cache.remember(key, const []);

    expect(await cache.read(key), isNull);
  });

  test('clear empties every key', () async {
    const otherKey = 'day:other-user';
    await TimelineBucketCache(ctx.db).remember(key, buckets);
    await TimelineBucketCache(ctx.db).remember(otherKey, buckets);

    await TimelineBucketCache.clear(ctx.db);

    expect(await sut.read(key), isNull);
    expect(await sut.read(otherKey), isNull);
  });

  test('a list turned away before a clear is not written back after it', () async {
    final cache = TimelineBucketCache(ctx.db, writeEvery: const Duration(milliseconds: 50));
    await cache.remember(key, buckets);
    await cache.remember(key, <Bucket>[TimeBucket(date: DateTime(2000), assetCount: 1)]);

    // A sign-out inside the write window: the held list belongs to the account that just left.
    await TimelineBucketCache.clear(ctx.db);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(await cache.read(key), isNull);
  });

  test('a list whose query started before a clear is not written after it', () async {
    final cache = TimelineBucketCache(ctx.db, writeEvery: Duration.zero);
    final startedAt = DateTime.now();

    // A sign-out while the bucket query is running: its answer arrives after the clear, but describes the old account.
    await TimelineBucketCache.clear(ctx.db);
    await cache.remember(key, buckets, startedAt: startedAt);

    expect(await cache.read(key), isNull);
  });

  test('a clear from another isolate stops a held list too', () async {
    final cache = TimelineBucketCache(ctx.db, writeEvery: const Duration(milliseconds: 50));
    await cache.remember(key, buckets);
    await cache.remember(key, <Bucket>[TimeBucket(date: DateTime(2000), assetCount: 1)]);

    // What a server-requested reset in the sync isolate leaves behind: the rows and the time, but none of this
    // isolate's memory.
    await ctx.db.customStatement(
      'INSERT OR REPLACE INTO $kOfflineSchema.timeline_buckets_cleared (id, cleared_at) VALUES (0, ?1)',
      [DateTime.now().microsecondsSinceEpoch],
    );
    await ctx.db.customStatement('DELETE FROM $kOfflineSchema.timeline_buckets');
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(await cache.read(key), isNull);
  });

  test('a list whose query started after a clear is written', () async {
    final cache = TimelineBucketCache(ctx.db, writeEvery: Duration.zero);
    await TimelineBucketCache.clear(ctx.db);

    await cache.remember(key, buckets, startedAt: DateTime.now());

    expect(await cache.read(key), buckets);
  });

  test('the same list is written again after a clear', () async {
    final cache = TimelineBucketCache(ctx.db, writeEvery: Duration.zero);
    await cache.remember(key, buckets);
    await TimelineBucketCache.clear(ctx.db);

    // Signing back in to the same library: unchanged from what this instance last wrote, but no longer on disk.
    await cache.remember(key, buckets);

    expect(await cache.read(key), buckets);
  });

  group('a damaged row misses rather than throws', () {
    test('written by a build with a different format', () async {
      await writeRow(format: 99, bucketCount: 1, payload: '2026-08-24T00:00:00.000|47');
      expect(await sut.read(key), isNull);
    });

    test('holding fewer buckets than it claims', () async {
      await writeRow(format: 1, bucketCount: 3, payload: '2026-08-24T00:00:00.000|47');
      expect(await sut.read(key), isNull);
    });

    test('holding more buckets than it claims', () async {
      await writeRow(format: 1, bucketCount: 1, payload: '2026-08-24T00:00:00.000|47\n2026-08-23T00:00:00.000|12');
      expect(await sut.read(key), isNull);
    });

    test('truncated mid-line', () async {
      await writeRow(format: 1, bucketCount: 2, payload: '2026-08-24T00:00:00.000|47\n2026-08-23T00:00');
      expect(await sut.read(key), isNull);
    });

    test('holding something that is not a date', () async {
      await writeRow(format: 1, bucketCount: 1, payload: 'the eighth of never|47');
      expect(await sut.read(key), isNull);
    });

    test('holding something that is not a count', () async {
      await writeRow(format: 1, bucketCount: 1, payload: '2026-08-24T00:00:00.000|many');
      expect(await sut.read(key), isNull);
    });

    test('holding a count of zero', () async {
      await writeRow(format: 1, bucketCount: 1, payload: '2026-08-24T00:00:00.000|0');
      expect(await sut.read(key), isNull);
    });

    test('empty', () async {
      await writeRow(format: 1, bucketCount: 0, payload: '');
      expect(await sut.read(key), isNull);
    });
  });

  test('a database without the schema misses, and writing to it is not an error', () async {
    // Every test in the suite that builds a plain `Drift` is this case: no `offline` schema, so not even the table
    // exists. It has to behave as an ordinary miss, because that is the app running exactly as it did before.
    final bare = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    addTearDown(bare.close);

    await expectLater(TimelineBucketCache.ensureSchema(bare), completes);

    final cache = TimelineBucketCache(bare);
    await expectLater(cache.remember(key, buckets), completes);
    expect(await cache.read(key), isNull);
  });

  test('a second write in the same window leaves the first one standing', () async {
    await sut.remember(key, buckets);
    await sut.remember(key, <Bucket>[TimeBucket(date: DateTime(2000), assetCount: 1)]);

    expect(await sut.read(key), buckets);
  });

  test('the newest list turned away inside the window is written when it closes', () async {
    final cache = TimelineBucketCache(ctx.db, writeEvery: const Duration(milliseconds: 50));
    final middle = <Bucket>[TimeBucket(date: DateTime(2001), assetCount: 2)];
    final last = <Bucket>[TimeBucket(date: DateTime(2000), assetCount: 1)];

    await cache.remember(key, buckets);
    await cache.remember(key, middle);
    await cache.remember(key, last);
    expect(await cache.read(key), buckets);

    await Future<void>.delayed(const Duration(milliseconds: 150));

    // A session whose final change lands just after a write must not hand the next launch the earlier list.
    expect(await cache.read(key), last);
  });
  test('the same list under a new key is still written', () async {
    final cache = TimelineBucketCache(ctx.db, writeEvery: const Duration(milliseconds: 50));
    const otherKey = 'day:other-user';

    await cache.remember(key, buckets);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // A partner added who has nothing in the timeline: a new key, the same list.
    await cache.remember(otherKey, buckets);

    expect(await cache.read(otherKey), buckets);
  });

  test('lists turned away for two keys inside the window are both written', () async {
    final cache = TimelineBucketCache(ctx.db, writeEvery: const Duration(milliseconds: 50));
    const otherKey = 'day:other-user';
    final mine = <Bucket>[TimeBucket(date: DateTime(2001), assetCount: 2)];
    final theirs = <Bucket>[TimeBucket(date: DateTime(2000), assetCount: 1)];

    await cache.remember(key, buckets);
    await cache.remember(key, mine);
    await cache.remember(otherKey, theirs);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(await cache.read(key), mine);
    expect(await cache.read(otherKey), theirs);
  });
}
