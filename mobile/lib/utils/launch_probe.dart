/// immich-sync fork — **temporary instrumentation**, for a TestFlight reporter's launch.
///
/// The complaint: tens of seconds after opening before the first photo appears, on a large library and a fast phone.
///
/// The first round-trip settled the shape of it. On a 532,068-asset library the launch sync was done at +442ms, the
/// timeline's bucket query produced its *first and only* emission at +20,367ms, and the screen drew 37ms later. So the
/// query is not being re-run by the sync's writes and superseded — it runs once and does not come back. What made that
/// conclusive was an accident: a plain `SELECT COUNT(*)` issued at +148ms did not return until +18,271ms either. Two
/// unrelated reads, both starved, so the answer is about the *database read path*, not about one statement.
///
/// What this version is for, then, is the question that is left: whether that path is starved because the bucket query
/// is inherently expensive, or because the pages it needs are cold and are being read off flash a page at a time. So:
///
///   * [watchDatabase] asks the database for `SELECT 1` once a second until the bucket query answers. It costs nothing
///     and touches no table, so its duration is purely how long the connection made it wait — this is the reading the
///     last round had to infer from a `COUNT(*)` that happened to be there.
///   * once that stops, and only then, it counts the library and measures the file, because a duration means nothing
///     without the number of assets and the number of megabytes it was measured over.
///   * [warmRerun] runs the bucket query a second time *after* the cold one answers, when its pages are in cache. Cold
///     minus warm is the share that is I/O, and there is no other way to separate the two.
///
/// The last two are deliberately after the wait rather than during it. Last round the probe ran a duplicate bucket
/// query and two counts while the timeline was starving, and so competed for the very thing it was measuring.
///
/// Everything here is `info`, because that is the root level a stock install actually records (`LogService.create`
/// reads `SettingsKey.logLevel`, default `LogLevel.info`); `fine` would be dropped on the reporter's device and waste
/// the attempt. The volume is bounded on purpose — the log keeps only `kLogTruncateLimit` rows and this must not push
/// the interesting part out of it.
///
/// **Off** unless built with `--dart-define=MIRRICH_LAUNCH_PROBE=true` (`MIRRICH_LAUNCH_PROBE=1` in front of
/// `tools/build_release.sh` or `tools/build_android.sh`, or the define passed to `flutter run`). Switched on, it raises
/// the session's log level over the user's own choice and reads the largest table about ten times, plus a second full
/// bucket scan; none of that belongs in every launch. That includes debug and profile builds: a profile build is the
/// one launch timings are taken from, and a probe that is always on would be part of every number it produces.
///
/// Delete this file and its call sites once the answer is in.
library;

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:logging/logging.dart';

class LaunchProbe {
  /// Whether this build carries the probe at all. A constant, so a release build without the define compiles every
  /// call site down to nothing.
  static const enabled = bool.fromEnvironment('MIRRICH_LAUNCH_PROBE');

  static final Logger _log = Logger('LaunchProbe');

  /// Wall clock from process start, so every line can be read as "+Xms into the launch" without subtracting
  /// timestamps by hand.
  static final Stopwatch _clock = Stopwatch();

  /// How often the canary asks the database whether it is answering at all, and the ceiling on how long it keeps
  /// asking. A minute is longer than any launch worth waiting through, and sixty lines is a bounded cost.
  static const _canaryEvery = Duration(seconds: 1);
  static const _canaryLimit = 60;

  /// How long the warm re-run stands back after the cold query answers. The timeline fetches its first page of assets
  /// and their thumbnails the moment it draws, and a second full bucket query on top of that would be measuring
  /// contention again — the mistake this version exists to stop making.
  static const _warmRerunDelay = Duration(seconds: 5);

  /// Emissions reported one by one, per stream, before the summary takes over. Ten is enough to show a pattern — a
  /// burst of re-runs looks nothing like a single late arrival — and small enough to leave the rest of the log intact.
  static const _detailedEmissions = 10;

  /// After that, one line per this many, so a re-run storm still reports itself in a bounded way rather than going
  /// silent, which would leave a log that cannot be told apart from one where the stream simply settled.
  static const _summaryEvery = 100;

  static bool _painted = false;

  /// Whether the timeline's real bucket query (one with users) has answered. The canary and the warm re-run key off
  /// this, not the paint: the paint can come from the empty stream built before the user list resolves, or from last
  /// launch's cached list, and neither says the cold query is done.
  static bool _liveAnswered = false;

  /// The users the timeline actually queried with, kept so [_scale] can ask why the query answered as it did.
  static List<String> _timelineUsers = const [];
  static Future<void> Function()? _warmRerun;

  static String get _at => '+${_clock.elapsedMilliseconds}ms';

  /// Starts the clock. From the top of `main()`, and deliberately silent: `LogService` has not subscribed to
  /// `Logger.root` yet, so anything said here would go nowhere.
  static void start() {
    if (enabled && !_clock.isRunning) {
      _clock.start();
    }
  }

  /// Once logging exists — straight after `Bootstrap.initDomain()`, which is what installs it.
  static void ready() {
    if (!enabled) {
      return;
    }
    // `LogService.create` has just set the root level from the stored setting, so this has to come after it or be
    // silently undone. The reporter will not be walked through a log-level setting, and a level above info would
    // record none of what follows. In memory only: `LogService.setLogLevel` is what persists a choice, and this is
    // deliberately not that.
    if (Logger.root.level.value > Level.INFO.value) {
      final was = Logger.root.level.name;
      Logger.root.level = Level.INFO;
      _log.info('Raised the log level from $was to INFO for this session');
    }
    _log.info('$_at launch probe armed');
  }

  /// A one-line marker. Keep these few and name them so the sequence reads as a story.
  static void mark(String what) {
    if (enabled) {
      _log.info('$_at $what');
    }
  }

  /// Times [body] and reports it. For the handful of operations whose *duration* is the question.
  static Future<T> time<T>(String what, Future<T> Function() body) async {
    if (!enabled) {
      return body();
    }
    final started = _clock.elapsedMilliseconds;
    try {
      return await body();
    } finally {
      _log.info('$_at $what took ${_clock.elapsedMilliseconds - started}ms');
    }
  }

  /// Puts the probe on the database. From `main()`, as soon as there is one and a logger to report through.
  ///
  /// The canary runs first and alone; the library's size is only counted once the canary has stopped, which is when the
  /// bucket query answers or at the ceiling. Counting is a read of the biggest table there is, and a probe that
  /// competes for the thing it is measuring buys its number by making the number worse — which is exactly what the
  /// last round did.
  static void watchDatabase(Drift db) {
    if (!enabled) {
      return;
    }
    unawaited(_canary(db).whenComplete(() => _scale(db)));
  }

  /// How much library there is, and how much file it is stored in. Both one-shot, both timed — the timing is not
  /// incidental: last round these same counts took 18 seconds while the timeline waited, and that is what gave the
  /// starvation away. Cheap now that nothing is contending, and still the denominator every duration needs.
  static Future<void> _scale(Drift db) async {
    try {
      final remote = await time('counting the remote assets', () => db.managers.remoteAssetEntity.count());
      final local = await time('counting the local assets', () => db.managers.localAssetEntity.count());
      mark('library scale: $remote remote asset(s), $local local asset(s)');

      await _whyEmpty(db);

      final pages = await db.customSelect('PRAGMA page_count').getSingle();
      final size = await db.customSelect('PRAGMA page_size').getSingle();
      final bytes = pages.read<int>('page_count') * size.read<int>('page_size');
      mark('database file holds ${(bytes / (1024 * 1024)).round()} MiB');
    } catch (error) {
      mark('database scale probe failed: $error');
    }
  }

  /// Which half of the timeline's WHERE clause is throwing the library away.
  ///
  /// The bucket query answers nothing while the table holds tens of thousands of rows, and the three predicates that
  /// could do that — the owner, the visibility and the soft delete — are indistinguishable from the outside. This
  /// counts them one at a time, so a single launch says which. One-shot, after the canary, and it reads only the
  /// covering index the timeline itself uses.
  static Future<void> _whyEmpty(Drift db) async {
    try {
      final users = _timelineUsers;
      mark('the timeline queried for user(s): ${users.map(_short).join(', ')}');

      Future<int> count(String where, [List<String> args = const []]) async {
        final row = await db
            .customSelect(
              'SELECT COUNT(*) AS n FROM remote_asset_entity $where',
              variables: [for (final arg in args) Variable<String>(arg)],
            )
            .getSingle();
        return row.read<int>('n');
      }

      final owners = await db
          .customSelect('SELECT owner_id, COUNT(*) AS n FROM remote_asset_entity GROUP BY owner_id LIMIT 5')
          .get();
      mark(
        'assets by owner: '
        '${owners.map((r) => '${_short(r.read<String>('owner_id'))}=${r.read<int>('n')}').join(', ')}',
      );

      final visibilities = await db
          .customSelect('SELECT visibility, COUNT(*) AS n FROM remote_asset_entity GROUP BY visibility')
          .get();
      mark(
        'assets by visibility: '
        '${visibilities.map((r) => '${r.read<int>('visibility')}=${r.read<int>('n')}').join(', ')}',
      );

      mark('assets not soft-deleted: ${await count('WHERE deleted_at IS NULL')}');

      if (users.isNotEmpty) {
        final user = users.first;
        mark('for that user: ${await count('WHERE owner_id = ?1', [user])}');
        mark('  ...and visible: ${await count('WHERE owner_id = ?1 AND visibility = 0', [user])}');
        mark(
          '  ...and not deleted: '
          '${await count('WHERE owner_id = ?1 AND visibility = 0 AND deleted_at IS NULL', [user])}',
        );
      }
    } catch (error) {
      mark('emptiness probe failed: $error');
    }
  }

  /// Enough of an id to compare two of them, and no more.
  static String _short(String id) => id.length <= 8 ? id : '${id.substring(0, 8)}…';

  /// `SELECT 1` on a loop until the bucket query answers. It parses to a constant and reads no table, so its duration
  /// is purely how long the connection made it wait: seconds here means every reader is starved, milliseconds here
  /// beside a bucket query still outstanding means that one query is doing the work.
  static Future<void> _canary(Drift db) async {
    for (var probe = 0; probe < _canaryLimit && !_liveAnswered; probe++) {
      final started = _clock.elapsedMilliseconds;
      try {
        await db.customSelect('SELECT 1').getSingle();
      } catch (error) {
        mark('database canary failed: $error');
        return;
      }
      _log.info('$_at the database answered SELECT 1 in ${_clock.elapsedMilliseconds - started}ms');
      if (_liveAnswered) {
        return;
      }
      await Future<void>.delayed(_canaryEvery);
    }
  }

  /// Registers one re-run of the timeline's bucket query, to be made after the cold one answers. See the library
  /// comment: the point is the cold/warm difference, and it is only honest if the warm run is not competing with the
  /// cold one.
  ///
  /// First caller wins, so re-subscribing the timeline — which happens whenever its service is rebuilt — cannot queue
  /// a second one.
  static void warmRerun(Future<void> Function() rerun) {
    if (enabled) {
      _warmRerun ??= rerun;
    }
  }

  /// One bucket stream. The returned handle attributes emissions to the stream that produced them: at launch there are
  /// several, including one built before the user list resolves that queries nothing and returns instantly. Last round
  /// a single global counter mixed those together and very nearly cost us the reading.
  static BucketProbe bucketStream(List<String> users) {
    if (users.isNotEmpty) {
      _timelineUsers = users;
    }
    final probe = BucketProbe._(users.length, _clock.elapsedMilliseconds);
    if (enabled) {
      _log.info('$_at ${probe._name} subscribed');
    }
    return probe;
  }

  /// The moment the timeline has something to draw, which is what the reporter is timing. An empty build only counts
  /// once the real query has answered: before that it is the stream built before the user list resolved.
  static void firstPaint(int segments) {
    if (!enabled || _painted || (segments == 0 && !_liveAnswered)) {
      return;
    }
    _painted = true;
    _log.info('$_at TIMELINE FIRST PAINT — $segments segments');
  }

  /// The real bucket query's first answer: stops the canary, and schedules the warm re-run now that the cold one is
  /// no longer competing with it.
  static void _answered() {
    if (_liveAnswered) {
      return;
    }
    _liveAnswered = true;
    _log.info('$_at the bucket query answered for the first time');

    final rerun = _warmRerun;
    _warmRerun = null;
    if (rerun != null) {
      unawaited(Future<void>.delayed(_warmRerunDelay, () => time('the same bucket query, re-run warm', rerun)));
    }
  }
}

/// One subscription to the timeline's bucket query, with its own emission count and its own clock.
class BucketProbe {
  BucketProbe._(this._users, this._since) : _name = 'bucket stream #${++_streams} ($_users user(s))';

  static int _streams = 0;

  final String _name;
  final int _users;
  int _since;
  int _emissions = 0;

  /// One emission of this stream's query. The gap since the previous one is the discriminating number: a steady
  /// trickle means the query runs and is being superseded, one long silence means it never got to run.
  void emitted(int buckets) {
    if (!LaunchProbe.enabled) {
      return;
    }
    _emissions++;
    if (_users > 0) {
      LaunchProbe._answered();
    }
    final now = LaunchProbe._clock.elapsedMilliseconds;
    final gap = now - _since;
    _since = now;

    if (_emissions <= LaunchProbe._detailedEmissions) {
      LaunchProbe._log.info('${LaunchProbe._at} $_name emission #$_emissions after ${gap}ms ($buckets buckets)');
    } else if (_emissions % LaunchProbe._summaryEvery == 0) {
      LaunchProbe._log.info(
        '${LaunchProbe._at} $_name emission #$_emissions, still re-running (last gap ${gap}ms, $buckets buckets)',
      );
    }
  }
}
