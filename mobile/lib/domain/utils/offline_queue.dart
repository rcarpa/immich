/// immich-sync fork: the order files are fetched in and how many at once. The service decides what the phone should
/// hold; this downloads it.
///
/// Two lanes. Thumbnails and previews are many small files, latency-bound: as many at once as an adaptive limit finds
/// the server takes ([OfflineConcurrencyLimit]), in the foreground. Originals and videos are few large ones,
/// bandwidth-bound: a few at once, resumed where they stopped, and carried on by the system once the app leaves the
/// screen. On Android the native side keeps the process running while there is work (a lease this renews), so both
/// lanes simply carry on; elsewhere the small files stop and a batch of large ones is handed over.
library;

import 'dart:async';
import 'dart:collection';

import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/utils/offline_concurrency.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_download.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:logging/logging.dart';

/// How many full-size files download at once in the foreground. They share the link, so more only slows each down.
const _maxRunningFullSize = 3;

/// How many full-size files are handed to the system when the app leaves the screen and cannot stay running. It runs
/// three at a time and finishes the rest on its own schedule.
const _maxHandedOver = 10;

/// How long the mirror gives way to upstream's backup before downloading anyway, so a backup that never finishes
/// cannot stop the mirror for good.
const _maxYield = Duration(minutes: 2);

/// How often a queue that has work but may not start it looks again. Every reason it stops clears on its own, and
/// none announces it.
const _retryStopped = Duration(seconds: 30);

/// How long the queue holds off once failures that are not the file's fault keep coming, doubling up to the ceiling.
/// Only after [_backoffAfter] in a row with no success between them: with many downloads running, one timeout says
/// little about the server.
const _backoffAfter = 3;
const _backoffStart = Duration(seconds: 30);
const _backoffMax = Duration(minutes: 30);

/// How many times a thumbnail or preview may fail for a network reason, with other files arriving in between, before
/// it counts as a failure of its own. Full-size files resume where they stopped, so each attempt gets further.
const _maxStrikes = 5;

/// How many waiting files are looked for on disk at once.
const _adoptBatch = 200;

/// How often the keep-alive lease is renewed while there is work. The native side lets it lapse after 90 s.
const _keepAliveRenewal = Duration(seconds: 30);

class OfflineMissingFile {
  const OfflineMissingFile(
    this.assetId,
    this.file, {
    required this.touchedAt,
    required this.createdAt,
    this.isErrand = false,
  });

  final String assetId;
  final OfflineFile file;

  /// Saved by hand (*Save offline*). Outranks every standing decision.
  final bool isErrand;

  final int touchedAt;
  final int createdAt;

  /// The order: errands, then the most recent decision, then the cheapest file within it, then the newest photo.
  /// Decisions come before rungs, so switching one album to full quality during a library-wide sync fetches that album
  /// first.
  static int compare(OfflineMissingFile a, OfflineMissingFile b) {
    if (a.isErrand != b.isErrand) {
      return a.isErrand ? -1 : 1;
    }
    if (a.touchedAt != b.touchedAt) {
      return b.touchedAt.compareTo(a.touchedAt);
    }
    final order = a.file.variant.fetchOrder.compareTo(b.file.variant.fetchOrder);
    return order != 0 ? order : b.createdAt.compareTo(a.createdAt);
  }
}

class OfflineDownloadQueue {
  OfflineDownloadQueue(
    this._downloads,
    this._settings, {
    required this.onHeld,
    required this.onDownloaded,
    required this.onFailed,
    required this.onLetGo,
    required this.onChanged,
    required this.onDrained,
    required this.hasRoom,
    required this.isBackingUp,
    required this.mayUseNetwork,
    this.lookOnDisk = offlineAdoptAll,
    OfflineConcurrencyLimit? limit,
  }) : _limit = limit ?? OfflineConcurrencyLimit();

  final OfflineDownloadRepository _downloads;
  final SettingsRepository _settings;
  final OfflineConcurrencyLimit _limit;
  static final _log = Logger('OfflineDownloadQueue');

  /// A file arrived, or was found already on disk.
  final void Function(OfflineHeldRow row) onHeld;

  /// A file was downloaded; [onHeld] is called for it too.
  final void Function(OfflineHeldRow row) onDownloaded;

  /// A download failed for a reason that is the file's own ([OfflineFailureKind.file]).
  final void Function(OfflineMissingFile entry, OfflineDownloadException error) onFailed;

  /// A file was dropped after a failure that is not its own. The next pass brings it back if it is still wanted: only
  /// a pass knows that, and the queue may have been replaced while it ran.
  final void Function() onLetGo;

  final void Function() onChanged;

  /// The last running download finished and nothing is waiting.
  final void Function() onDrained;

  /// Whether the store is under its limit. Asked before every file, since it moves as files land.
  final bool Function() hasRoom;

  /// Whether upstream's backup is uploading. The mirror gives way: uploads are the user's only copy leaving the phone.
  /// Activity, not the backlog, since a photo that cannot upload would block the mirror for ever (see [_maxYield]).
  final bool Function() isBackingUp;

  /// Whether the current network may be used, which the Wi-Fi only setting decides.
  final Future<bool> Function() mayUseNetwork;

  /// The sizes of those of [names] already in the store, which are claimed instead of fetched.
  final Future<Map<String, int>> Function(String root, List<String> names) lookOnDisk;

  final _pending = ListQueue<OfflineMissingFile>();

  /// Waiting files found not to be on disk, so a top-up after every download does not look again. Forgotten when the
  /// queue is replaced: a pass is when files that arrived some other way are noticed.
  final _notOnDisk = <String>{};
  final _running = <String, _Run>{};
  int _runningFullSize = 0;

  bool _suspended = false;
  bool _networkAllowed = true;
  bool _filling = false;
  bool _finishedSinceDrain = false;
  Timer? _retry;
  DateTime? _yieldingSince;
  DateTime? _backingOffUntil;
  Duration _backoff = _backoffStart;
  int _transientStreak = 0;

  /// Downloads that succeeded, so a strike against a file counts only once the server has shown it is up.
  int _successes = 0;
  final _strikes = <String, ({int count, int at})>{};

  /// The user stopped the transfer while the app was away. Honoured until it is on screen again, as natively.
  bool _stoppedByUser = false;

  /// Whether the native side keeps the process running in the background, as of the last renewal.
  bool _keptAlive = false;
  DateTime? _keepAliveRenewedAt;
  bool _keepAliveHadWork = false;
  Future<bool>? _renewing;

  /// Files downloading now.
  int get queued => _running.length;

  int get pending => _pending.length;

  bool get isIdle => _running.isEmpty && _pending.isEmpty;

  /// Names of the files downloading now.
  Set<String> get inFlight => _running.keys.toSet();

  /// What is waiting or running, so the integrity pass does not sweep a file about to land.
  Iterable<OfflineMissingFile> get entries => [..._running.values.map((run) => run.entry), ..._pending];

  /// How many small files may run at once now.
  int get lightLimit => _limit.limit;

  bool get _isPaused => _settings.appConfig.offlinePaused;

  /// In the background without the process kept running: small files wait, large ones are left to the system.
  bool get _inBackground => _suspended && !_keptAlive;

  String? get stoppedBecause => _inBackground ? 'the app is in the background' : _stoppedAnyway;

  /// Why nothing may start, whether in the foreground or the background.
  String? get _stoppedAnyway {
    if (_stoppedByUser) {
      return 'stopped by the user';
    }
    if (_isPaused) {
      return 'paused';
    }
    if (!hasRoom()) {
      return 'at the storage limit';
    }
    if (!_networkAllowed) {
      return 'waiting for Wi-Fi';
    }
    if (_yieldingToBackup) {
      return 'giving way to the backup';
    }
    if (_backingOff) {
      return 'waiting for the server to be reachable';
    }
    return null;
  }

  bool get _backingOff {
    final until = _backingOffUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// Giving way to the backup, but at most [_maxYield].
  bool get _yieldingToBackup {
    if (!isBackingUp()) {
      _yieldingSince = null;
      return false;
    }
    final since = _yieldingSince ??= DateTime.now();
    return DateTime.now().difference(since) < _maxYield;
  }

  /// A download failed for a reason that is not the file's. Once that keeps happening, hold off, longer each time the
  /// reason persists. Ignored while already holding off, since the other running files fail for the same reason.
  void backOff() {
    if (_backingOff || ++_transientStreak < _backoffAfter) {
      return;
    }
    _transientStreak = 0;
    _backingOffUntil = DateTime.now().add(_backoff);
    final next = _backoff * 2;
    _backoff = next > _backoffMax ? _backoffMax : next;
  }

  void _noteSucceeded() {
    _successes++;
    _transientStreak = 0;
    _backingOffUntil = null;
    _backoff = _backoffStart;
  }

  /// Replaces what is waiting. Running files keep going.
  void replace(List<OfflineMissingFile> found) {
    found.sort(OfflineMissingFile.compare);
    _notOnDisk.clear();
    _pending
      ..clear()
      ..addAll(found.where((entry) => !_running.containsKey(entry.file.name)));
    if (_pending.isEmpty) {
      _cancelRetry();
    }
  }

  /// Follows the app in and out of the foreground. In the background the process may be kept running (Android), and
  /// then nothing changes; otherwise small files are aborted and wait at the front of the queue, while large ones keep
  /// going in the system's hands.
  void setSuspended(bool suspended) {
    if (_suspended == suspended) {
      return;
    }
    _suspended = suspended;
    if (suspended) {
      unawaited(_enterBackground());
    } else {
      _stoppedByUser = false;
      unawaited(topUp());
    }
    onChanged();
  }

  Future<void> _enterBackground() async {
    // Asked now rather than trusted from the last renewal: the lease may have lapsed, or the user stopped it.
    await _renewKeepAlive(force: true);
    if (!_suspended || _keptAlive) {
      return;
    }
    _abortRunning(requeue: true, lightOnly: true);
    _cancelRetry();
    await _handOver();
    onChanged();
  }

  /// Starts the full-size files at the front of the queue, up to [_maxHandedOver], for the system to finish while the
  /// app is away. Small files ahead of them stay where they are.
  Future<void> _handOver() async {
    if (_filling) {
      return;
    }
    _filling = true;
    try {
      _networkAllowed = await mayUseNetwork();
      if (!_inBackground || _stoppedAnyway != null) {
        return;
      }
      final root = await offlineStoreRoot();
      // Looked for at once and in an isolate, as [topUp] does: the queue may be long, and the app is leaving the screen
      final names = [
        for (final entry in _pending)
          if (entry.file.variant.isFullSize && !_notOnDisk.contains(entry.file.name)) entry.file.name,
      ];
      final onDisk = names.isEmpty ? const <String, int>{} : await lookOnDisk(root, names);
      _notOnDisk.addAll(names.where((name) => !onDisk.containsKey(name)));
      if (!_inBackground || _stoppedAnyway != null) {
        return;
      }
      final kept = <OfflineMissingFile>[];
      while (_pending.isNotEmpty && _runningFullSize < _maxHandedOver && _stoppedAnyway == null) {
        final entry = _pending.removeFirst();
        final name = entry.file.name;
        if (!entry.file.variant.isFullSize) {
          kept.add(entry);
          continue;
        }
        // One queued during the lookup is checked on its own.
        final size = onDisk[name] ?? (_notOnDisk.contains(name) ? null : offlineAdopt(root, name));
        if (size != null) {
          onHeld(_heldRow(entry, size));
          continue;
        }
        _start(entry, offlinePinnedPath(root, entry.file.name));
      }
      for (final entry in kept.reversed) {
        _pending.addFirst(entry);
      }
    } finally {
      _filling = false;
    }
  }

  /// How many times [clear] ran. A pass compares it before and after, so files it found are not queued after a stop.
  int get clears => _clears;
  int _clears = 0;

  /// Drops everything, aborting what is running, and cancels downloads a previous engine left running natively.
  void clear() {
    _clears++;
    _pending.clear();
    _notOnDisk.clear();
    _strikes.clear();
    _abortRunning(requeue: false);
    _cancelRetry();
    unawaited(_downloads.cancelAll());
    unawaited(_renewKeepAlive(force: true));
  }

  void dispose() {
    _abortRunning(requeue: false);
    _cancelRetry();
  }

  void _abortRunning({required bool requeue, bool lightOnly = false}) {
    final aborted = [
      for (final run in _running.values)
        if (!lightOnly || !run.entry.file.variant.isFullSize) run,
    ];
    if (aborted.isEmpty) {
      return;
    }
    for (final run in aborted) {
      _running.remove(run.entry.file.name);
      if (run.entry.file.variant.isFullSize) {
        _runningFullSize--;
      }
      run.abort.complete();
    }
    if (requeue) {
      final entries = aborted.map((run) => run.entry).toList()..sort(OfflineMissingFile.compare);
      for (final entry in entries.reversed) {
        _pending.addFirst(entry);
      }
    }
  }

  void _cancelRetry() {
    _retry?.cancel();
    _retry = null;
  }

  /// Comes back for work that could not be started. Not while paused or in the background, which both resume it.
  void _retryLater() {
    if (_isPaused || _inBackground || (_retry?.isActive ?? false)) {
      return;
    }
    _retry = Timer(_retryStopped, () {
      _retry = null;
      if (_pending.isNotEmpty) {
        unawaited(topUp());
      }
    });
  }

  /// Renews the keep-alive lease while there is work, and gives it up once there is none. Throttled: a renewal is a
  /// channel round trip, and this runs after every file.
  Future<bool> _renewKeepAlive({bool force = false}) {
    final hasWork = !isIdle && !_isPaused;
    final renewedAt = _keepAliveRenewedAt;
    final due =
        force ||
        hasWork != _keepAliveHadWork ||
        renewedAt == null ||
        DateTime.now().difference(renewedAt) >= _keepAliveRenewal;
    final inFlight = _renewing;
    if (!due) {
      return Future.value(_keptAlive);
    }
    if (inFlight != null && !force) {
      return inFlight;
    }
    _keepAliveHadWork = hasWork;
    _keepAliveRenewedAt = DateTime.now();
    final renewal = _downloads
        .keepAlive(pending: hasWork ? _pending.length + _running.length : 0, wifiOnly: _wifiOnly)
        .then((kept) {
          final wasKept = _keptAlive;
          _keptAlive = kept;
          // Lost while away: the user stopped it, or the system did. Give way as if it had never been granted.
          if (wasKept && !kept && _suspended) {
            unawaited(_enterBackground());
          }
          return kept;
        });
    _renewing = renewal;
    return renewal.whenComplete(() {
      if (identical(_renewing, renewal)) {
        _renewing = null;
      }
    });
  }

  bool get _wifiOnly => _settings.appConfig.offlineWifiOnly;

  /// Starts downloads until every slot is busy, claiming files already on disk instead of fetching them.
  Future<void> topUp() async {
    if (_filling) {
      return;
    }
    if (_inBackground) {
      await _handOver();
      onChanged();
      return;
    }
    _filling = true;
    try {
      _networkAllowed = await mayUseNetwork();
      final root = await offlineStoreRoot();
      var claimed = 0;
      var onDisk = const <String, int>{};
      while (stoppedBecause == null && _pending.isNotEmpty) {
        // The head of a lane with room; else the queue's head, which may still be claimed off disk.
        final startable = _nextStartable();
        final entry = startable ?? _pending.first;
        final name = entry.file.name;
        if (!onDisk.containsKey(name) && !_notOnDisk.contains(name)) {
          // Looked for in a batch, in an isolate: after a reinstall most of the queue may already be on disk.
          final names = [
            name,
            for (final next in _pending.take(_adoptBatch))
              if (next.file.name != name && !_notOnDisk.contains(next.file.name)) next.file.name,
          ];
          onDisk = await lookOnDisk(root, names);
          _notOnDisk.addAll(names.where((name) => !onDisk.containsKey(name)));
          // The queue may have been replaced meanwhile.
          continue;
        }
        final size = onDisk[name];
        if (size != null) {
          _take(entry);
          onHeld(_heldRow(entry, size));
          // Yield now and then during a run of claims.
          if (++claimed % 50 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
          continue;
        }
        if (startable == null) {
          break;
        }
        _take(entry);
        _start(entry, offlinePinnedPath(root, entry.file.name));
      }
    } finally {
      _filling = false;
      if (_pending.isNotEmpty && _running.isEmpty && stoppedBecause != null) {
        _retryLater();
      }
      unawaited(_renewKeepAlive());
      onChanged();
      if (isIdle && _finishedSinceDrain) {
        _finishedSinceDrain = false;
        onDrained();
      }
    }
  }

  /// The first waiting file of a lane with a free slot. Each lane keeps the queue's order, and neither waits on the other.
  OfflineMissingFile? _nextStartable() {
    final heavyRoom = _runningFullSize < _maxRunningFullSize;
    final lightRoom = _running.length - _runningFullSize < _limit.limit;
    if (!heavyRoom && !lightRoom) {
      return null;
    }
    for (final entry in _pending) {
      if (entry.file.variant.isFullSize ? heavyRoom : lightRoom) {
        return entry;
      }
    }
    return null;
  }

  void _take(OfflineMissingFile entry) {
    if (identical(_pending.first, entry)) {
      _pending.removeFirst();
    } else {
      _pending.remove(entry);
    }
  }

  void _start(OfflineMissingFile entry, String path) {
    final heavy = entry.file.variant.isFullSize;
    final run = _Run(entry, heavy ? null : _limit.start());
    _running[entry.file.name] = run;
    // Looked for again if it comes back: it may have landed, as when aborted just as it finished.
    _notOnDisk.remove(entry.file.name);
    if (heavy) {
      _runningFullSize++;
    }
    unawaited(_download(run, path));
  }

  Future<void> _download(_Run run, String path) async {
    final entry = run.entry;
    final name = entry.file.name;
    final heavy = entry.file.variant.isFullSize;
    final stopwatch = Stopwatch()..start();
    var letGo = false;
    var cancelledNatively = false;
    try {
      final size = await _downloads.fetch(
        entry.file.url,
        path,
        lane: heavy ? OfflineLane.heavy : OfflineLane.light,
        checksum: entry.file.checksum,
        wifiOnly: _wifiOnly,
        abort: run.abort.future,
      );
      if (run.abort.isCompleted) {
        // Finished as it was aborted; the file is on disk and the next claim records it.
        return;
      }
      _noteSucceeded();
      _strikes.remove(name);
      final ticket = run.ticket;
      if (ticket != null) {
        _limit.onSuccess(ticket, stopwatch.elapsed);
      }
      final row = _heldRow(entry, size);
      try {
        onHeld(row);
        onDownloaded(row);
      } catch (error, stack) {
        // The file is complete, so this is not held against it; the next claim records it.
        _log.severe('Recording the download of ${entry.assetId} ${entry.file.variant.name} failed', error, stack);
      }
    } on OfflineDownloadCancelled {
      if (run.abort.isCompleted) {
        return;
      }
      // Stopped on the native side, not here: the user stopped the keep-alive.
      cancelledNatively = true;
      letGo = true;
      if (_suspended) {
        _stoppedByUser = true;
      }
    } on OfflineDownloadException catch (error) {
      if (run.abort.isCompleted) {
        return;
      }
      _log.warning('Download failed: ${entry.assetId} ${entry.file.variant.name} <${entry.file.url}> — $error');
      switch (error.kind) {
        case OfflineFailureKind.file:
          _strikes.remove(name);
          onFailed(entry, error);
        case OfflineFailureKind.transient:
          final ticket = run.ticket;
          if (ticket != null) {
            _limit.onTransientFailure(ticket);
          }
          backOff();
          if (!heavy && _strike(name) >= _maxStrikes) {
            // Other files arrive and this one never does: the server has a problem with it.
            _strikes.remove(name);
            onFailed(entry, error);
          } else {
            letGo = true;
          }
      }
    } catch (error, stack) {
      if (run.abort.isCompleted) {
        return;
      }
      // Counted against the file rather than let go, which would queue it again at once if it comes back every time.
      _log.severe('Download of ${entry.assetId} ${entry.file.variant.name} failed unexpectedly', error, stack);
      _strikes.remove(name);
      onFailed(entry, OfflineDownloadException('Unexpected error: $error'));
    } finally {
      if (!run.abort.isCompleted) {
        _finishedSinceDrain = true;
        if (identical(_running[name], run)) {
          _running.remove(name);
          if (heavy) {
            _runningFullSize--;
          }
        }
      }
    }
    if (letGo) {
      onLetGo();
    }
    if (cancelledNatively) {
      // Asked first, so the native side is told it may let the keep-alive go.
      unawaited(_renewKeepAlive(force: true).then((_) => topUp()));
      return;
    }
    unawaited(topUp());
  }

  /// Counts a network failure against [name], but only once since the last success of any file.
  int _strike(String name) {
    final last = _strikes[name];
    final next = last == null
        ? (count: 1, at: _successes)
        : last.at < _successes
        ? (count: last.count + 1, at: _successes)
        : last;
    _strikes[name] = next;
    return next.count;
  }

  OfflineHeldRow _heldRow(OfflineMissingFile entry, int size) => OfflineHeldRow(
    name: entry.file.name,
    assetId: entry.assetId,
    variant: entry.file.variant,
    token: entry.file.token,
    size: size,
  );
}

/// One running download and the means to abort it on its own.
class _Run {
  _Run(this.entry, this.ticket);

  final OfflineMissingFile entry;

  /// The concurrency limit's ticket; null for full-size files, which have their own fixed limit.
  final int? ticket;
  final abort = Completer<void>();
}
