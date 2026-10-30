import 'dart:async';

import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:logging/logging.dart';

/// immich-sync fork: last launch's timeline bucket list, so this launch does not have to compute it before it can draw.
///
/// The grid cannot lay out until it knows how many photos fall on every day in the library, and working that out means
/// visiting every asset there is: on a 532,068-asset library, 145 MB of scattered page reads to produce 5,736 numbers,
/// which is twenty seconds on a phone reading cold. The photos those numbers index are not the problem — the first
/// screenful of them is one index walk and about six milliseconds. So the wait is for a table of contents, over
/// content that was ready before the splash screen finished.
///
/// A table of contents that barely changes between launches. This writes it down.
///
/// # Nothing here is trusted
///
/// The cache is a *hint*, and the app is expected to behave identically without it — which is also how it behaves when
/// this file fails at anything. Every entry point swallows its errors and answers "no cache", and "no cache" is
/// exactly today's behaviour: wait for the real query. That is the whole recovery story, and it covers a database this
/// table was never created in (every test that builds a `Drift` over an in-memory connection, where the `offline`
/// schema does not exist at all), a row from a build whose format has changed, a payload that does not parse, and a
/// payload that parses into the wrong number of buckets.
///
/// There is deliberately **no shutdown hook**. Nothing has to happen at the end of a session for the next one to be
/// correct, because the only failure a half-finished write could produce is one this already handles. The write itself
/// is a single `INSERT OR REPLACE`, so SQLite gives it to us whole or not at all: the row is the previous complete
/// value, or the new complete value, or absent.
///
/// # When it is emptied
///
/// The rows live outside `main`, so nothing that empties upstream's tables reaches them on its own. [clear] is called
/// wherever the library it describes is thrown away — `SyncStreamRepository.reset()`, which is both sign-out and a
/// server-requested reset, and `Drift.reset()` — so a later launch cannot draw a library that is no longer there, and a
/// signed-out account's per-day counts do not stay on disk. A library that empties itself (everything deleted) is
/// handled by [remember]: an empty live answer deletes the row rather than leaving the last non-empty one standing.
///
/// A clear also has to stop lists computed before it from being written back after it: one held back by the write
/// window, or a query that was already running when the library went and answers a moment later. So the time of the
/// last clear is stored in the database, beside the rows, and a write carries the time its query *started*: a list
/// whose query started before the last clear is dropped. In the database rather than in memory because the clear can
/// come from another isolate — a server-requested reset runs inside the sync isolate, while the timeline, and so every
/// write, is on the main one.
///
/// # What it is allowed to get wrong
///
/// Staleness, and only in one direction that matters. Under-reporting is harmless — fewer slots than there are photos,
/// corrected the moment the live query lands. Over-reporting means the grid lays out slots the assets behind cannot
/// fill, which `TimelineService._loadAssets` now answers with a short row rather than a `RangeError`; see the note
/// there, which is a hazard that predates this and that a sync deleting rows under a live timeline could already hit.
///
/// # Where it lives
///
/// In the fork's attached schema, next to `OfflineFlagsRepository`'s tables and for its reasons: this is derived data
/// with no shape to migrate, so idempotent DDL says everything a migration would, and keeping it out of upstream's
/// `schemaVersion` keeps a number line we do not control from meaning two things. Every statement names the schema, so
/// nothing here can resolve against a `main` table by accident.
final class TimelineBucketCache {
  TimelineBucketCache(this._db, {Duration writeEvery = _writeEvery}) : _writeGap = writeEvery;

  final Drift _db;

  static final Logger _log = Logger('TimelineBucketCache');

  static const _table = '$kOfflineSchema.timeline_buckets';

  /// One row: when [clear] last ran, in microseconds since the epoch. See "When it is emptied".
  static const _clearedTable = '$kOfflineSchema.timeline_buckets_cleared';

  /// Bumped whenever [_encode] changes. A row written by an older build is discarded, never guessed at.
  static const _format = 1;

  /// The longest this may keep the timeline waiting. A single lookup by primary key on a table with one row per user
  /// set; if that has not answered by now something is wrong enough that the live query is the better bet, and the
  /// cache must never be able to make a launch slower than it was without it.
  static const _readBudget = Duration(milliseconds: 250);

  /// The shortest gap between two writes. The list only changes as the library does, and rewriting a hundred-odd
  /// kilobytes for every sync commit would cost more than the read it saves.
  static const _writeEvery = Duration(seconds: 30);

  /// Refuse anything absurd rather than hold it in memory. A day per bucket over thirty years is ~11,000; six figures
  /// is not a library, it is a corrupt row.
  static const _maxBuckets = 100000;

  final Duration _writeGap;

  /// Bumped by a [clear] in this isolate, so a list this instance last wrote is not mistaken for one still on disk.
  /// Static, because [clear] is called from code that holds no instance.
  static int _clears = 0;

  /// The value of [_clears] that [_wroteKey] and [_wrote] were recorded under.
  int _wroteIn = 0;

  DateTime? _wroteAt;

  /// What the last write stored, and under which key. Both, because a different key with the same list — a partner
  /// added who has nothing in the timeline — is a row that does not exist yet.
  String? _wroteKey;
  String? _wrote;

  /// The newest list per key that a write inside the window turned away, written when the window closes. Without it, a
  /// session's last change landing within [_writeEvery] of the previous write would leave the next launch drawing the
  /// older list. Per key, so a switch of key inside the window cannot drop the other key's latest list.
  final Map<String, (List<Bucket>, DateTime)> _pending = {};
  Timer? _pendingTimer;

  /// Creates the table if it is missing, on every launch. Never throws: a cache that cannot be created is a cache that
  /// misses, and a launch must not fail over one.
  static Future<void> ensureSchema(Drift db) async {
    try {
      await db.customStatement('''
        CREATE TABLE IF NOT EXISTS $_table (
          cache_key    TEXT    NOT NULL PRIMARY KEY,
          format       INTEGER NOT NULL,
          -- Written beside the payload and checked against it on the way back in. SQLite's atomicity should make a
          -- half-written row impossible; this costs one integer and means we do not have to rely on that being true.
          bucket_count INTEGER NOT NULL,
          buckets      TEXT    NOT NULL,
          computed_at  TEXT    NOT NULL
        )
      ''');
      await db.customStatement('''
        CREATE TABLE IF NOT EXISTS $_clearedTable (
          id         INTEGER NOT NULL PRIMARY KEY CHECK (id = 0),
          cleared_at INTEGER NOT NULL
        )
      ''');
    } catch (error) {
      _log.fine('Could not ensure the timeline bucket cache table', error);
    }
  }

  /// Deletes every cached list, and stops any list whose query started before now from being written later. Never
  /// throws, for the same reason [ensureSchema] does not.
  static Future<void> clear(Drift db) async {
    _clears++;
    try {
      // The time first: once it is down, nothing computed before it can land, so the delete after it is final.
      await db.customStatement('INSERT OR REPLACE INTO $_clearedTable (id, cleared_at) VALUES (0, ?1)', [
        DateTime.now().microsecondsSinceEpoch,
      ]);
      await db.customStatement('DELETE FROM $_table');
    } catch (error) {
      _log.fine('Could not clear the timeline bucket cache', error);
    }
  }

  /// What the cached list is a list *of*. Sorted, so the same set of users cannot produce two entries; a set that no
  /// longer matches — a partner added, a different account, a different grouping — simply misses.
  static String keyFor(List<String> userIds, GroupAssetsBy groupBy) =>
      '${groupBy.name}:${(userIds.toList()..sort()).join(',')}';

  /// The stored list, or null for every reason there could be — including a table that does not exist.
  Future<List<Bucket>?> read(String key) async {
    try {
      final row = await _db
          .customSelect(
            'SELECT format, bucket_count, buckets FROM $_table WHERE cache_key = ?1 LIMIT 1',
            variables: [Variable<String>(key)],
          )
          .getSingleOrNull()
          .timeout(_readBudget);
      if (row == null || row.read<int>('format') != _format) {
        return null;
      }
      return _decode(row.read<String>('buckets'), row.read<int>('bucket_count'));
    } catch (error) {
      _log.fine('Ignoring the timeline bucket cache', error);
      return null;
    }
  }

  /// Writes [buckets] down for the next launch, at most every [_writeEvery] and never when it would change nothing. A
  /// list arriving inside the window is held and written when it closes, so the newest one always lands.
  ///
  /// Best effort by design: the caller does not await this and nothing observes whether it worked.
  ///
  /// An empty list is never stored, so a cache hit is always something worth drawing and [read] never has to decide
  /// whether "no buckets" means an empty library or a bad row. It deletes the row instead: a library that has emptied
  /// must not be drawn from an older, fuller list on the next launch.
  ///
  /// [startedAt] is when the query that produced [buckets] started, and defaults to now. A list whose query started
  /// before the last [clear] is dropped.
  Future<void> remember(String key, List<Bucket> buckets, {DateTime? startedAt}) =>
      _remember(key, buckets, startedAt ?? DateTime.now());

  Future<void> _remember(String key, List<Bucket> buckets, DateTime startedAt) async {
    if (buckets.length > _maxBuckets) {
      return;
    }
    final wroteAt = _wroteAt;
    if (wroteAt != null) {
      final wait = _writeGap - DateTime.now().difference(wroteAt);
      if (wait > Duration.zero) {
        _pending[key] = (buckets, startedAt);
        _pendingTimer ??= Timer(wait, () {
          _pendingTimer = null;
          final pending = Map.of(_pending);
          _pending.clear();
          for (final entry in pending.entries) {
            unawaited(_remember(entry.key, entry.value.$1, entry.value.$2));
          }
        });
        return;
      }
    }
    _pending.remove(key);
    if (_pending.isEmpty) {
      _pendingTimer?.cancel();
      _pendingTimer = null;
    }
    await _write(key, buckets, startedAt);
  }

  Future<void> _write(String key, List<Bucket> buckets, DateTime startedAt) async {
    try {
      final now = DateTime.now();
      final clears = _clears;
      final payload = _encode(buckets);
      // What was last written may have been cleared since, so it only counts as "unchanged" within the same clear.
      if (payload == null || (_wroteIn == clears && key == _wroteKey && payload == _wrote)) {
        return;
      }
      if (buckets.isEmpty) {
        // Always allowed: removing a row can never put an old library back.
        await _db.customStatement('DELETE FROM $_table WHERE cache_key = ?1', [key]);
      } else {
        // In the statement, not checked beforehand, so a clear from another isolate cannot land between the check and
        // the write.
        final written = await _db.customUpdate(
          'INSERT OR REPLACE INTO $_table (cache_key, format, bucket_count, buckets, computed_at) '
          'SELECT ?1, ?2, ?3, ?4, ?5 '
          'WHERE NOT EXISTS (SELECT 1 FROM $_clearedTable WHERE cleared_at >= ?6)',
          variables: [
            Variable<String>(key),
            const Variable<int>(_format),
            Variable<int>(buckets.length),
            Variable<String>(payload),
            Variable<String>(now.toUtc().toIso8601String()),
            Variable<int>(startedAt.microsecondsSinceEpoch),
          ],
        );
        if (written == 0) {
          _log.fine('Dropped a bucket list computed before the cache was last cleared');
          return;
        }
      }
      _wroteAt = now;
      _wroteIn = clears;
      _wroteKey = key;
      _wrote = payload;
    } catch (error) {
      _log.fine('Could not write the timeline bucket cache', error);
    }
  }

  /// One `<iso date>|<count>` per line.
  ///
  /// The date goes through `toIso8601String`/`parse` rather than an epoch offset because that pair round-trips a
  /// `DateTime` exactly, including whether it is UTC — which `DateTime ==` compares, so an approximation here would
  /// make every cached bucket differ from its live twin and force a rebuild that changes nothing on screen.
  ///
  /// Returns null for anything it cannot represent, which is [remember]'s cue to write nothing at all.
  static String? _encode(List<Bucket> buckets) {
    final lines = <String>[];
    for (final bucket in buckets) {
      if (bucket is! TimeBucket) {
        return null;
      }
      lines.add('${bucket.date.toIso8601String()}|${bucket.assetCount}');
    }
    return lines.join('\n');
  }

  /// Total, by construction: every path that is not a complete, well-formed list of exactly [count] buckets returns
  /// null, and null is a miss.
  static List<Bucket>? _decode(String payload, int count) {
    if (count <= 0 || count > _maxBuckets) {
      return null;
    }
    final lines = payload.split('\n');
    if (lines.length != count) {
      return null;
    }
    final buckets = <Bucket>[];
    for (final line in lines) {
      final separator = line.lastIndexOf('|');
      if (separator <= 0) {
        return null;
      }
      final date = DateTime.tryParse(line.substring(0, separator));
      final assetCount = int.tryParse(line.substring(separator + 1));
      if (date == null || assetCount == null || assetCount <= 0) {
        return null;
      }
      buckets.add(TimeBucket(date: date, assetCount: assetCount));
    }
    return buckets;
  }
}
