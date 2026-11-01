/// immich-sync fork: keeps the offline store in line with what the user selected. [check] is cheap and runs often,
/// [sync] finds and queues missing files, and [reclaim] walks the whole store on its own isolate, weekly or on demand.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/utils/offline_changes.dart';
import 'package:immich_mobile/domain/utils/offline_files.dart';
import 'package:immich_mobile/domain/utils/offline_index.dart';
import 'package:immich_mobile/domain/utils/offline_ledger.dart';
import 'package:immich_mobile/domain/utils/offline_queue.dart';
import 'package:immich_mobile/domain/utils/offline_space.dart';
import 'package:immich_mobile/infrastructure/repositories/offline.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_download.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/utils/async_mutex.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:immich_mobile/utils/offline_reclaim.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Rows per page, and the missing files one [sync] looks for before stopping.
const _pageSize = 500;
const _missingBudget = 3000;

/// A burst of changes postpones the pass it asks for by [_checkDelay] each time, but never beyond [_checkMaxWait].
const _checkMaxWait = Duration(seconds: 20);
const _checkDelay = Duration(seconds: 3);

/// How long the first pass after launch waits, so it does not compete with the timeline's first query.
const _launchDelay = Duration(seconds: 10);

const _reclaimInterval = Duration(days: 7);

/// Held while inside the pass lock. Methods that read the mirror's state and then change it take one, so calling them
/// outside the lock does not compile; only [OfflineSyncService._exclusive] makes it.
final class _Pass {
  _Pass._(this._service, this._interrupts, this._clears);

  final OfflineSyncService _service;

  /// Both read when the pass was asked for, not when it got the lock: a stop or a wipe that came while it waited
  /// counts too.
  final int _interrupts;
  final int _clears;

  /// Whether downloads were stopped (sign-out, pause) since the pass was asked for, so what it finds is not queued.
  bool get downloadsStopped => _service._queue.clears != _clears;

  /// Called between pages of a long walk: gives the lock up to a wipe that is waiting for it.
  void checkInterrupted() {
    if (_service._interrupts != _interrupts) {
      throw const _PassInterrupted();
    }
  }
}

/// A wipe asked for the lock while a pass held it.
final class _PassInterrupted implements Exception {
  const _PassInterrupted();
}

class OfflineSyncService {
  OfflineSyncService(
    this._repository,
    this._flags,
    this._downloads,
    this._settings, {
    Future<bool> Function()? mayUseNetwork,
  }) {
    _status = _status.copyWith(isPaused: _settings.appConfig.offlinePaused);
    _index.publish();
    offlineListenForStoreActivity(_onStoreActivity);
    offlineOnRead = (name) => _ledger.noteRead(name);
    _queue = OfflineDownloadQueue(
      _downloads,
      _settings,
      // The queue's downloads are aborted by a wipe, so whatever it reports is current.
      onHeld: (row) => _bufferHeld(row, _ledger.ticket()),
      onDownloaded: (row) => unawaited(_flags.clearFailure(row.name)),
      onFailed: _onFailed,
      onLetGo: _changes.noteLetGo,
      onChanged: () => _emitSoon(_queueCountsOn(_status)),
      onDrained: _onDrained,
      hasRoom: _isUnderLimit,
      isBackingUp: () => _isBackingUp?.call() ?? false,
      mayUseNetwork: mayUseNetwork ?? () async => true,
    );
    _ready = _prepareStore().then((_) => _loadIndex());
  }

  /// Once per store: renames files older builds kept under the server's path prefix.
  Future<void> _prepareStore() async {
    try {
      if (await _flags.storeUnprefixed()) {
        return;
      }
      final databasePath = await offlineDatabasePath();
      final pinnedRoot = p.join(await offlineStoreRoot(), kOfflinePinnedDirectory);
      final moved = await _ledger.walk(
        () => offlineUnprefixStore(databasePath: databasePath, pinnedRoot: pinnedRoot),
        changed: (moved) => moved,
      );
      await _flags.setStoreUnprefixed();
      if (moved > 0) {
        _log.info('Renamed $moved file(s) stored under the server path');
      }
    } catch (error, stackTrace) {
      _log.warning('Could not rename files stored under the server path', error, stackTrace);
    }
  }

  final OfflineRepository _repository;
  final OfflineFlagsRepository _flags;
  final OfflineDownloadRepository _downloads;
  final SettingsRepository _settings;
  final _log = Logger('OfflineSyncService');

  /// Whether upstream's backup is busy; the mirror starts no downloads meanwhile.
  bool Function()? _isBackingUp;
  void bindBackupActivity(bool Function() isBackingUp) => _isBackingUp = isBackingUp;

  void noteLocalAssetsChanged() => _changes.noteLocal();

  void noteUpstreamChanged() => _changes.noteUpstream();

  /// Counts a write as it happens; [noteUpstreamChanged] asks for the pass once the writes settle.
  void noteUpstreamWrite() => _changes.noteUpstreamWrite();

  final _index = OfflineIndex();

  late final OfflineDownloadQueue _queue;
  late final Future<void> _ready;

  final _statusController = StreamController<OfflineStatus>.broadcast();
  OfflineStatus _status = const OfflineStatus();

  final _passes = AsyncMutex();

  /// Whether a pass is due, and when one may settle.
  final _changes = OfflineChanges();

  /// Every change to what the store holds: files, `held`, [_index] and the native sets.
  late final _ledger = OfflineLedger(_flags, _index, onRecorded: _evictSoon);

  bool _evictionPending = false;

  final _space = OfflineSpace();

  Timer? _emitTimer;
  Timer? _revisionTimer;
  Timer? _checkTimer;

  DateTime? _checkAskedAt;

  Stream<OfflineStatus> get status => _statusController.stream;
  OfflineStatus get current => _status;

  OfflineAvailability availabilityOf(String assetId) => _index.availabilityOf(assetId);

  OfflineQuality wantedOf(String assetId) => _index.wantedOf(assetId);

  OfflineBar barOf(String assetId) => _index.barOf(assetId);

  bool get _isPaused => _settings.appConfig.offlinePaused;

  int get _limit => _settings.appConfig.offlineStorageLimit;

  /// Whether the store may still grow. Spares are evicted before this says no.
  bool _isUnderLimit() => _space.hasRoom(held: _index.heldBytes, limit: _limit);

  Future<void> _measureDevice() async => _space.measure(held: _index.heldBytes, free: await offlineFreeSpace());

  /// Waits for the store to be ready itself, after reading what the pass compares against: a caller that waited first
  /// would let a stop or a wipe in between go unnoticed.
  Future<T> _exclusive<T>(Future<T> Function(_Pass pass) action) async {
    final interrupts = _interrupts;
    final clears = _queue.clears;
    await _ready;
    return _passes.run(() => action(_Pass._(this, interrupts, clears)));
  }

  /// Bumped by [deleteAll], so a long pass, running or waiting for the lock, gives it up at its next page instead of
  /// making the wipe wait.
  int _interrupts = 0;

  void _emit(OfflineStatus next) {
    _status = next;
    if (!_statusController.isClosed) {
      _statusController.add(next);
    }
  }

  void _emitSoon(OfflineStatus next) {
    _status = next;
    if (_emitTimer?.isActive ?? false) {
      return;
    }
    _emitTimer = Timer(const Duration(milliseconds: 500), () {
      if (!_statusController.isClosed) {
        _statusController.add(_status);
      }
    });
  }

  void _scheduleRevisionBump() {
    if (_revisionTimer?.isActive ?? false) {
      return;
    }
    _revisionTimer = Timer(const Duration(seconds: 4), () {
      _emit(_status.copyWith(revision: _status.revision + 1));
    });
  }

  Future<void> _loadIndex() async {
    try {
      await _ledger.reload();
      _remainingAt = null;
      _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
    } catch (error, stackTrace) {
      _log.severe('Could not read what is stored offline', error, stackTrace);
    }
  }

  /// Looks up the sizes of every full-size file still to download, for the estimate of what is left. Each item once:
  /// after the first pass only new selections and items upstream had no size for are asked about. Outside the pass
  /// lock, since the first lookup reads the whole selection.
  Future<void> _lookUpSizes() async {
    if (_lookingUpSizes) {
      return;
    }
    final ids = _index.idsLackingSizes();
    if (ids.isEmpty) {
      return;
    }
    _lookingUpSizes = true;
    try {
      _index.applySizes(await _repository.sizesOf(ids));
      _remainingAt = null;
      _emit(_countsOn(_status));
    } catch (error, stackTrace) {
      _log.warning('Could not read the sizes for the download estimate', error, stackTrace);
    } finally {
      _lookingUpSizes = false;
    }
  }

  bool _lookingUpSizes = false;

  /// The estimate of what is left, recomputed at most every couple of seconds: it walks every wanted item, and files
  /// land many times a second. Shown to two digits, so nobody sees it lag.
  OfflineRemaining? _remainingCache;
  DateTime? _remainingAt;
  static const _remainingEvery = Duration(seconds: 2);

  OfflineRemaining get _remaining {
    final now = DateTime.now();
    final at = _remainingAt;
    final cached = _remainingCache;
    if (cached != null && at != null && now.difference(at) < _remainingEvery) {
      return cached;
    }
    _remainingAt = now;
    return _remainingCache = _index.remaining(originalVideos: _settings.appConfig.viewer.loadOriginalVideo);
  }

  OfflineStatus _countsOn(OfflineStatus status) {
    final remaining = _remaining;
    return status.copyWith(
      wantedAssets: _index.wantedAssets,
      wanted: _index.wantedFiles,
      held: _index.heldFiles,
      bytes: _index.heldBytes,
      remainingBytes: remaining.bytes,
      remainingIsExact: remaining.exact,
    );
  }

  OfflineStatus _queueCountsOn(OfflineStatus status) {
    final reason = _queue.stoppedBecause;
    return status.copyWith(
      queued: _queue.queued,
      pending: _queue.pending,
      waitingBecause: reason,
      clearWaiting: reason == null,
    );
  }

  OfflinePolicy get policy => OfflinePolicy.decode(_settings.appConfig.offlinePolicy);

  /// Applies [change] to the selection and re-derives everything it covers.
  ///
  /// Re-deriving is one statement, so every change re-derives everything rather than working out what it touched.
  Future<void> applyPolicy(OfflinePolicy Function(OfflinePolicy current) change) async {
    await _exclusive((pass) async {
      final previous = policy;
      final next = change(previous);
      if (next == previous) {
        return;
      }
      await _settings.write(SettingsKey.offlinePolicy, next.encode());
      await _rederive(pass, next);
    });
    await _afterImperativeChange();
  }

  /// Re-derives every decision, and tells the screens if anything moved.
  ///
  /// Stamped when the change is made, so the queue follows the order decisions were taken in.
  Future<void> _rederive(_Pass _, [OfflinePolicy? selection]) async {
    final changed = await _flags.derive(selection ?? policy, DateTime.now());
    if (changed == 0) {
      return;
    }
    await _loadIndex();
    _log.info('Re-derived the selection; $changed decision(s) moved');
    _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
  }

  /// Drops albums upstream no longer has from the selection.
  ///
  /// Otherwise a deleted album stays in the selection for ever, and an excluded one keeps hiding its photos. Only once
  /// upstream is complete: mid-sync its tables hold assets before albums, and every album would look deleted.
  Future<void> _forgetVanishedAlbums(_Pass pass) async {
    final named = {...policy.albums.keys, ...policy.excluded};
    if (named.isEmpty) {
      return;
    }
    final vanished = (await _flags.vouch(
      () async => named.difference(await _repository.existingAlbumIds(named)),
    )).ifComplete;
    if (vanished == null || vanished.isEmpty) {
      return;
    }

    final next = vanished.fold(policy, (current, id) => current.withAlbum(id, OfflineAlbumState.notIncluded));
    await _settings.write(SettingsKey.offlinePolicy, next.encode());
    await _rederive(pass, next);
    _log.info('Forgot ${vanished.length} album(s) upstream no longer has');
  }

  ({int wanted, int available}) progressOf(Iterable<String> assetIds) {
    var wanted = 0;
    var available = 0;
    for (final id in assetIds) {
      if (_index.wantedOf(id).isWanted) {
        wanted++;
        // Against the item's own rung, so previews-only does not read as done once thumbnails land.
        if (_index.availabilityOf(id).covers(_index.wantedOf(id).availableAt)) {
          available++;
        }
      }
    }
    return (wanted: wanted, available: available);
  }

  /// *Save offline*: fetches these items at full quality now. They stay as spares until freed.
  Future<void> fetchForOffline(Iterable<String> assetIds) async {
    await _ready;
    final ids = assetIds.toList();
    final details = await _repository.detailsFor(ids);
    // Which albums select each item. Asked of the policy, not the index, which would read a previous errand as
    // selected.
    final albums = await _repository.albumsOf(ids);

    await _exclusive((_) async {
      // Under the lock, so it writes against the latest selection.
      final policy = this.policy;
      final now = DateTime.now();
      final rows = <OfflineFlagRow>[];
      for (final asset in details.values) {
        final selected = policy.resolve(albums[asset.id] ?? const []);
        // Re-stamped even when the decision is unchanged, which moves it to the front of the queue.
        rows.add(
          OfflineFlagRow(
            id: asset.id,
            // What the selection maintains, not what the errand fetches: the reclaim bands read this column. The
            // errand's wider rung comes from its mark (`wanted.pinned`).
            quality: selected ?? kOfflineErrandQuality,
            createdAt: asset.createdAt,
            touchedAt: now,
            // A selection-derived row when a selection covers it, so its maintained files are not reclaimable.
            onDemand: selected == null,
          ),
        );
      }

      await _flags.set(rows);
      // Existing copies count as just used, so eviction takes them last.
      await _flags.touchAssets(rows.map((row) => row.id), now);
      // The errand mark puts these ahead of everything else in the queue, which `on_demand` cannot say when a selection
      // also covers the item.
      await _flags.addErrands([for (final row in rows) row.id]);
      for (final row in rows) {
        _index.noteErrand(row.id, errand: true);
      }
      for (final row in rows) {
        final asset = details[row.id]!;
        _index.setWanted(
          row.id,
          row.quality,
          isImage: asset.isImage,
          hasMotion: asset.motionVideoId != null,
          onDemand: row.onDemand,
        );
      }
      _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
    });

    await _afterImperativeChange();
  }

  /// Undoes [fetchForOffline]: what the errand added goes, what the selection asks for stays.
  Future<void> releaseOnDemand(Iterable<String> assetIds) async {
    await _ready;
    final ids = assetIds.toList();
    final details = await _repository.detailsFor(ids);
    final albums = await _repository.albumsOf(ids);

    await _exclusive((_) async {
      final policy = this.policy;
      final now = DateTime.now();
      final rows = <OfflineFlagRow>[];
      final forgotten = <String>[];

      for (final id in ids) {
        final asset = details[id];
        final quality = asset == null ? null : policy.resolve(albums[id] ?? const []);
        if (quality == null) {
          forgotten.add(id);
          continue;
        }
        rows.add(OfflineFlagRow(id: id, quality: quality, createdAt: asset!.createdAt, touchedAt: now));
      }

      await _flags.set(rows);
      await _flags.forget(forgotten);
      await _flags.dropErrands(ids);
      for (final id in ids) {
        _index.noteErrand(id, errand: false);
      }
      for (final row in rows) {
        final asset = details[row.id]!;
        _index.setWanted(row.id, row.quality, isImage: asset.isImage, hasMotion: asset.motionVideoId != null);
      }
      for (final id in forgotten) {
        _index.setWanted(id, OfflineQuality.none, isImage: details[id]?.isImage ?? true);
      }
      _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
    });

    // A pass rebuilds the queue, which still holds the full-size files the errand asked for. Not awaited: the caller
    // offers to free up space next.
    unawaited(_afterImperativeChange());
  }

  Future<OfflineStorage> storage() => _flags.storage();

  /// The most the app may hold in total, or zero for no limit. Lowering it evicts spares, never the library.
  Future<void> setStorageLimit(int bytes) async {
    await _settings.write(SettingsKey.offlineStorageLimit, bytes);
    await _exclusive(_evict);
    if (_isUnderLimit()) {
      await sync();
    }
  }

  Future<OfflineReclaimPlan> reclaimPlan({
    Iterable<String>? assetIds,
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) => _flags.reclaimPlan(assetIds: assetIds, what: what);

  Future<Map<OfflineReclaimCell, int>> reclaimBytesByCell(OfflineReclaim what) => _flags.reclaimBytesByCell(what);

  Future<Map<String, int>> spareBytesByAsset() => _flags.reclaimableBytesByAsset();

  /// The only control that deletes stored files.
  Future<void> freeUpSpace({Iterable<String>? assetIds, OfflineReclaim what = OfflineReclaim.notMaintained}) async {
    await _ready;
    await _ledger.flush();

    await _exclusive((pass) async {
      if (what.pauses) {
        await _setPaused(true);
      }
      String? cursor;
      var freed = 0;

      while (true) {
        // A wipe waiting for the lock removes everything anyway.
        try {
          pass.checkInterrupted();
        } on _PassInterrupted {
          return;
        }
        final files = assetIds == null
            ? await _flags.reclaimableFiles(limit: _pageSize, afterName: cursor, what: what)
            : await _flags.reclaimableFilesFor(assetIds, what: what);
        if (files.isEmpty) {
          break;
        }
        cursor = files.last.name;

        // A page at a time, which keeps the screen responsive.
        final failed = await _ledger.remove(files);
        if (failed > 0) {
          _log.warning('$failed file(s) could not be deleted; the integrity pass will retry them');
        }
        freed += files.length;
        _emit(_countsOn(_status));
        if (assetIds != null) {
          break;
        }
      }

      await _flags.dropFetchedWithoutFiles();
      await _loadIndex();
      _log.info('Freed $freed file(s)');
      _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
    });

    // Making room can restart downloading, and only a pass re-reads the limit.
    await _afterImperativeChange();
  }

  Future<void> _afterImperativeChange() async {
    _changes.invalidate();
    await sync();
  }

  /// [check], coalesced, for remote-side changes. A burst costs one pass a few seconds after its last event, but never
  /// later than [_checkMaxWait] after the first, so a long upload still gets passes.
  void checkSoon() {
    final askedAt = _checkAskedAt ??= DateTime.now();
    final remaining = _checkMaxWait - DateTime.now().difference(askedAt);
    _checkTimer?.cancel();
    _checkTimer = Timer(remaining < _checkDelay ? (remaining.isNegative ? Duration.zero : remaining) : _checkDelay, () {
      _checkAskedAt = null;
      unawaited(check());
    });
  }

  /// The cheap pass: does nothing unless something moved; otherwise re-derives and looks for what is missing.
  Future<void> check({bool download = true}) async {
    await _check(download: download);
  }

  Future<void> _check({bool download = true}) async {
    await _exclusive((pass) async {
      try {
        if (await _repository.assetCount() == 0) {
          return;
        }

        // Also not idle while the queue has work, since a task that never reports back would otherwise leave it parked.
        if (_changes.isSettled(revision: _flags.revision, videoForm: offlineVideoForm()) &&
            _queue.isIdle &&
            _status.lastError == null) {
          _log.fine('Nothing changed since the last pass');
          return;
        }

        await _forgetVanishedAlbums(pass);
        await _rederive(pass);
        await _sync(pass, download: download);
      } catch (error, stackTrace) {
        _log.warning('Change check failed', error, stackTrace);
      }
    });
  }

  /// Finds missing files and queues them. Never deletes.
  Future<void> sync({bool download = true}) async {
    await _exclusive((pass) => _sync(pass, download: download));
  }

  Future<void> _sync(_Pass pass, {required bool download}) async {
    _emit(_status.copyWith(isWorking: true, clearError: true));

    // Claimed now, and given up at the end only if no write overtook the pass. A file the queue lets go after this
    // marks the next pass due again.
    final start = _changes.begin(download: download);
    // Downloads stopped meanwhile (sign-out, pause) are not started again by what this pass found.
    bool cleared() => pass.downloadsStopped;
    try {
      // A pass that waited behind a wipe has nothing left to do.
      pass.checkInterrupted();
      // Half-synced, a missing asset may only be missing for now, so the pass never settles.
      final upstreamComplete = (await _flags.vouch(() async {})).complete;

      if (await _repository.assetCount() == 0 && _index.wantedAssets > 0) {
        // A database being repopulated (fresh install, reset or sign-out), not an instruction to drop everything.
        _log.info('No assets known yet; leaving the mirror untouched');
        _changes.fail(start);
        return;
      }

      // Free space moves with everything else on the phone; spares make room before the queue is told there is none.
      await _dropLocked(pass);
      await _measureDevice();
      if (!_isUnderLimit()) {
        await _evict(pass);
      }
      final inFlight = _queue.inFlight;
      final abandoned = await _flags.abandoned();
      final errands = await _flags.errands();

      // Built aside and swapped in at the end, since downloads top the queue up outside this lock.
      final found = <OfflineMissingFile>[];
      final satisfiedErrands = <String>{};
      final localCopyMoved = <String, bool>{};
      final walk = await _collectMissing(
        pass,
        found,
        inFlight: inFlight,
        abandoned: abandoned,
        errands: errands,
        satisfiedErrands: satisfiedErrands,
        localCopyMoved: localCopyMoved,
      );

      // The index keeps a copy of whether the camera roll holds each item, for the badge; correct it from the walk.
      if (localCopyMoved.isNotEmpty) {
        localCopyMoved.forEach((id, localCopy) => _index.noteLocalCopy(id, localCopy: localCopy));
        _emit(_status.copyWith(revision: _status.revision + 1));
        _log.info('${localCopyMoved.length} item(s) changed hands with the camera roll');
      }

      // Drop the errand mark as soon as its files are here, or it keeps outranking newer decisions.
      if (satisfiedErrands.isNotEmpty) {
        await _flags.dropErrands(satisfiedErrands);
        for (final id in satisfiedErrands) {
          _index.noteErrand(id, errand: false);
        }
        _emit(_status.copyWith(revision: _status.revision + 1));
        _log.fine('${satisfiedErrands.length} errand(s) complete');
      }

      final complete = walk.complete;
      var unavailable = walk.unavailable;

      // A decision about a photo the server no longer has is dropped now rather than at the weekly integrity pass.
      if (walk.walkedAll && walk.unresolved.isNotEmpty) {
        final gone =
            (await _flags.vouch(() async {
              final known = await _repository.existingIds(walk.unresolved);
              // Also hidden ones: the video half of a Live Photo, now fetched as part of its photo.
              final hidden = await _repository.hiddenIds(walk.unresolved);
              return [
                for (final id in walk.unresolved)
                  if (!known.contains(id) || hidden.contains(id)) id,
              ];
            })).ifComplete ??
            const <String>[];
        if (gone.isNotEmpty) {
          for (final id in gone) {
            unavailable -= _index.wantedFilesOf(id);
          }
          await _flags.forget(gone);
          await _loadIndex();
          _log.info('Forgot ${gone.length} decision(s) about items the mirror no longer keeps on their own');
        }
      }

      // A read-only pass only updates the figures; loading the queue without handing anything over would leave it
      // stuck.
      final enqueue = download && !cleared();
      if (enqueue) {
        _queue.replace(found);
      } else if (download) {
        // Stopped: what this pass claimed is owed to the next one.
        _changes.fail(start);
      }
      unawaited(_lookUpSizes());

      final stopped = _queue.stoppedBecause;
      _log.info(
        'Pass: ${found.length} missing found, ${inFlight.length} downloading, ${abandoned.length} given up on'
        '${complete ? ', whole list read' : ', stopped at the budget'}'
        '${enqueue ? '' : (download ? ', stopped meanwhile' : ', figures only')}'
        '${stopped == null ? '' : ', $stopped'}',
      );

      _emit(
        _queueCountsOn(_countsOn(_status)).copyWith(
          failed: await _flags.abandonedCount(),
          unavailable: walk.walkedAll ? unavailable : null,
          onDevice: walk.walkedAll ? walk.onDevice : null,
        ),
      );

      _changes.finish(
        start,
        walkedAll: walk.walkedAll,
        complete: complete,
        download: enqueue,
        upstreamComplete: upstreamComplete,
        revision: _flags.revision,
        videoForm: offlineVideoForm(),
      );

      _emit(_status.copyWith(isOverLimit: !_isUnderLimit()));

      if (enqueue && !cleared()) {
        await _queue.topUp();

        // Nothing was enqueued, so no completion will ask for the next page.
        if (!complete && !_isPaused && _queue.isIdle && !cleared()) {
          unawaited(sync());
        }
      }
    } on _PassInterrupted {
      _log.info('Pass interrupted by a wipe');
      _changes.fail(start);
      _changes.invalidate();
    } catch (error, stackTrace) {
      _log.warning('Sync failed', error, stackTrace);
      _changes.fail(start);
      _emit(_status.copyWith(lastError: error.toString()));
    } finally {
      _emit(_status.copyWith(isWorking: false));
    }
  }

  /// One walk of the wanted list, adding what is missing to [into], up to [_missingBudget] files in queue order:
  /// errands first, then decisions newest first, and within a decision the thumbnails and previews before the full-size
  /// files.
  Future<({bool walkedAll, bool complete, int unavailable, int onDevice, List<String> unresolved})> _collectMissing(
    _Pass pass,
    List<OfflineMissingFile> into, {
    required Set<String> inFlight,
    required Set<String> abandoned,
    required Set<String> errands,
    required Set<String> satisfiedErrands,
    required Map<String, bool> localCopyMoved,
  }) async {
    final chaseBase = await _flags.hasMissingBase();

    final urgent = <OfflineMissingFile>[];
    // Each decision's two halves; they move to [standing] when the walk leaves the decision.
    final standing = <OfflineMissingFile>[];
    final base = <OfflineMissingFile>[];
    final fullSize = <OfflineMissingFile>[];
    var truncated = false;

    void takeDecision() {
      for (final half in [base, fullSize]) {
        final room = _missingBudget - standing.length;
        truncated |= half.length > room;
        standing.addAll(half.take(room));
        half.clear();
      }
    }

    OfflineWantCursor? cursor;
    int? decision;
    var walkedAll = false;
    var unavailable = 0;
    var onDevice = 0;
    final unresolved = <String>[];

    while (true) {
      pass.checkInterrupted();
      final wants = await _flags.page(after: cursor, limit: _pageSize);
      if (wants.isEmpty) {
        walkedAll = true;
        break;
      }
      cursor = wants.last.cursor;

      // Thumbhash and storability come from upstream, so an edited or trashed asset is handled as it is now.
      final details = await _repository.detailsFor(wants.map((want) => want.id).toList());
      for (final want in wants) {
        if (want.touchedAt != decision) {
          takeDecision();
          decision = want.touchedAt;
        }
        final asset = details[want.id];
        if (asset == null) {
          unavailable += _index.wantedFilesOf(want.id);
          unresolved.add(want.id);
          continue;
        }
        if (want.localCopy != _index.localCopyOf(want.id)) {
          localCopyMoved[want.id] = want.localCopy;
        }
        final isErrand = errands.contains(want.id);
        // Files skipped because the camera roll holds them, counted apart from `unavailable` so progress can still
        // finish.
        final wantedFiles = offlineFilesFor(asset, want.quality, errand: isErrand);
        // Not for an asset the server has not processed yet: its files are coming.
        final skipped = asset.thumbHash.isEmpty ? 0 : _index.wantedFilesOf(want.id) - wantedFiles.length;
        if (skipped > 0) {
          onDevice += skipped;
        }

        // What the errand still waits for; a file in flight still counts.
        var awaited = 0;
        for (final file in wantedFiles) {
          final held = _index.holds(want.id, file.variant, file.token);
          if (!held && !abandoned.contains(file.name)) {
            awaited++;
          }
          if (held || inFlight.contains(file.name) || abandoned.contains(file.name)) {
            continue;
          }
          // Capped, so one decision's full-size half cannot grow to the size of the library.
          final bucket = isErrand
              ? urgent
              : file.variant.isFullSize
              ? fullSize
              : base;
          if (bucket.length < _missingBudget) {
            bucket.add(
              OfflineMissingFile(
                want.id,
                file,
                touchedAt: want.touchedAt,
                createdAt: want.createdAt,
                isErrand: isErrand,
              ),
            );
          } else {
            truncated = true;
          }
        }
        // An errand is done once its files are here. Never for an item that asks for nothing yet, such as a photo
        // uploaded seconds ago without a thumbnail: retiring the errand then would skip its full-size copy.
        if (isErrand && awaited == 0 && wantedFiles.isNotEmpty) {
          satisfiedErrands.add(want.id);
        }
      }

      // Stop once nothing else can fit: newer decisions come first and this one's cheap half fills the rest.
      if (base.length >= _missingBudget - standing.length ||
          (!chaseBase && fullSize.length >= _missingBudget - standing.length)) {
        break;
      }
    }
    takeDecision();

    // Errands keep their room whatever the walk found.
    into.addAll(urgent.take(_missingBudget));
    final room = _missingBudget - into.length;
    truncated |= standing.length > room;
    into.addAll(standing.take(room));

    // Whether every row was read (the counts are complete), and whether everything also fitted (the pass may settle).
    return (
      walkedAll: walkedAll,
      complete: walkedAll && !truncated,
      unavailable: unavailable,
      onDevice: onDevice,
      unresolved: unresolved,
    );
  }

  /// The integrity pass: walk the store, delete what nothing accounts for, and recount.
  Future<bool> reclaim() async {
    return _exclusive((pass) => _reclaim(pass));
  }

  /// [reclaim] past the share cap, once the user has confirmed a reduction a pass refused.
  Future<bool> confirmReclaim() async {
    final removed = await _exclusive((pass) => _reclaim(pass, confirmed: true));
    if (removed) {
      await sync();
    }
    return removed;
  }

  /// [reclaim] when due: weekly, after a deferred pass, or when the video form changed.
  Future<bool> reclaimIfDue() async {
    if (await _flags.reclaimPending() || await _videoFormChanged()) {
      return reclaim();
    }

    final last = await _flags.lastReclaim();
    if (last != null && DateTime.now().difference(last) < _reclaimInterval) {
      return false;
    }
    return reclaim();
  }

  Future<bool> _videoFormChanged() async {
    final recorded = await _flags.videoForm();
    return recorded != null && recorded != offlineVideoForm();
  }

  Future<bool> _reclaim(_Pass pass, {bool confirmed = false}) async {
    _emit(_status.copyWith(isWorking: true, clearError: true, refusedReclaim: 0));

    try {
      final startedAt = DateTime.now();
      final start = _changes.begin(download: false);
      if (await _repository.assetCount() == 0) {
        _log.info('No assets known yet; refusing to reclaim');
        return false;
      }
      // Early, so a half-synced library does not cost a walk that could not be used.
      if (!(await _flags.vouch(() async {})).complete) {
        _log.info('Upstream is still syncing; deferring the integrity pass');
        await _flags.setReclaimPending();
        return false;
      }

      // Changing the video form replaces every stored video, which the share guard would otherwise refuse.
      final form = offlineVideoForm();
      final recorded = await _flags.videoForm();
      final instructed = recorded != null && recorded != form;
      if (recorded == null) {
        // Baseline now, so a pass that stops early does not hide the next change.
        await _flags.setVideoForm(form);
      }

      // What may stay, read whole and vouched for: a half-populated database looks like a library emptied on the
      // server. A table that moved during the walk makes the set inconsistent too.
      final accounted = (await _flags.vouch(() => _accountedFor(pass))).ifComplete;
      if (accounted == null || _changes.upstreamMovedSince(start)) {
        _log.warning('Asset table moved during the integrity pass; deferring');
        await _flags.setReclaimPending();
        _emit(
          _status.copyWith(
            lastError: 'Waiting for syncing to finish before tidying up storage.',
            failed: await _flags.abandonedCount(),
          ),
        );
        return false;
      }

      final wantedHashes = accounted.keep;
      // Queued files too, or the walk deletes a file about to be replaced.
      for (final entry in _queue.entries) {
        wantedHashes.add(offlineNameHash(entry.file.name));
      }

      if (accounted.gone.isNotEmpty) {
        _log.info('Forgetting ${accounted.gone.length} decision(s) about photos the server no longer has');
        await _flags.forget(accounted.gone);
      }

      // The isolate uses a second connection, so arrivals wait for it.
      final root = await offlineStoreRoot();
      final databasePath = await offlineDatabasePath();
      final result = await _ledger.walk(
        () => offlineReclaimStore(
          databasePath: databasePath,
          pinnedRoot: p.join(root, kOfflinePinnedDirectory),
          wantedHashes: Int64List.fromList(wantedHashes),
          startedAt: startedAt,
          expected: instructed,
          confirmed: confirmed,
        ),
        changed: (result) => result.removed,
      );

      if (result.unreadable > 0 || result.failed > 0) {
        _log.warning(
          'Integrity pass could not read ${result.unreadable} file(s) and could not delete ${result.failed}',
        );
      }
      if (result.removed > 0) {
        _log.info('Reclaimed ${result.removed} file(s) no longer wanted');
        // The next check looks again.
        _changes.invalidate();
      }

      if (result.refused > 0) {
        _log.warning('Integrity pass refused to remove ${result.refused} file(s); the library is untouched');
        await _flags.setReclaimPending();
        _emit(
          _status.copyWith(
            // Shown on screen with a button, since only the user can tell a library cut down from one half-synced.
            refusedReclaim: result.refused,
            failed: await _flags.abandonedCount(),
          ),
        );
        await _loadIndex();
        return false;
      }

      await _flags.setReclaimed(DateTime.now());
      await _flags.setVideoForm(form);
      await _loadIndex();
      _emit(_status.copyWith(failed: await _flags.abandonedCount()));
      return result.removed > 0;
    } on _PassInterrupted {
      _log.info('Integrity pass interrupted by a wipe; deferring');
      await _flags.setReclaimPending();
      return false;
    } catch (error, stackTrace) {
      _log.warning('Reclaim failed', error, stackTrace);
      _emit(_status.copyWith(lastError: error.toString()));
      return false;
    } finally {
      _emit(_status.copyWith(isWorking: false));
    }
  }

  /// Queue what is missing, and verify the store if it is due.
  Future<void> reconcile({bool enqueue = true}) async {
    await check(download: enqueue);
    if (await reclaimIfDue()) {
      await sync(download: enqueue);
    }
  }

  /// Called after every foreground remote sync. Downloads follow when the server answered, even if the sync itself
  /// failed; only a finished one marks upstream's tables complete, and only if no reset came after it started
  /// ([resetGeneration], read then, or null if it could not be). The first call waits [_launchDelay], so the timeline
  /// has the database to itself while it first loads.
  void afterRemoteSync({required bool synced, required bool reachedServer, required int? resetGeneration}) {
    final delay = _sawRemoteSync ? Duration.zero : _launchDelay;
    _sawRemoteSync = true;
    unawaited(
      () async {
        // A finished sync is what makes upstream's tables trustworthy again after a wipe. Without the count it started
        // from, the next sync marks them instead.
        if (synced && resetGeneration != null && await _flags.setUpstreamComplete(ifGeneration: resetGeneration)) {
          _log.info('Upstream is complete; decisions may be dropped again');
          _changes.invalidate();
        }
        await Future<void>.delayed(delay);
        await reconcile(enqueue: reachedServer);
      }().catchError((Object error, StackTrace stack) => _log.warning('Offline reconcile failed', error, stack)),
    );
  }

  bool _sawRemoteSync = false;

  /// Stops downloading while the app is in the background, and resumes in the foreground.
  void setForeground(bool foreground) => _queue.setSuspended(!foreground);

  /// The server refused this file. Given up on after a few tries; a new thumbhash renames it. The queue cannot wait
  /// for this, so its errors are caught here: an unrecorded failure is one more try at the next pass.
  void _onFailed(OfflineMissingFile entry, OfflineDownloadException error) {
    unawaited(
      () async {
        await _flags.recordFailure(entry.file.name);
        _emitSoon(_status.copyWith(failed: await _flags.abandonedCount()));
      }().catchError(
        (Object error, StackTrace stack) => _log.warning('Could not record a failed download', error, stack),
      ),
    );
  }

  /// The queue ran dry. If the last pass stopped at its budget, or the queue let files go, there is more to look for.
  void _onDrained() {
    if (_changes.wantsPass && !_isPaused) {
      unawaited(sync());
    }
  }

  void _bufferHeld(OfflineHeldRow row, OfflineLedgerTicket ticket) {
    _ledger.record(row, ticket);
    _scheduleRevisionBump();
    _emitSoon(_countsOn(_status));
  }

  void _onStoreActivity(OfflineStoreActivity activity) {
    activity.read.forEach(_ledger.noteRead);
    if (activity.stored.isNotEmpty) {
      unawaited(
        _recordStored(activity.stored).catchError((Object error, StackTrace stack) {
          // Unrecorded files are claimed by the queue if wanted, and swept by the integrity pass if not.
          _log.warning('Could not record ${activity.stored.length} file(s) kept while browsing', error, stack);
        }),
      );
    }
  }

  /// Every stored file the integrity pass may keep, as name hashes, and the decisions about assets upstream has no row
  /// for. Reads upstream's tables throughout, so it is only acted on through [OfflineFlagsRepository.vouch].
  ///
  /// Deselecting never makes a file deletable; only "free up space" does. What goes: files of locked or gone assets,
  /// and thumbnails or previews of an older version of an asset, which the image path will never ask for again.
  Future<({List<int> keep, List<String> gone})> _accountedFor(_Pass pass) async {
    final keep = <int>[];
    String? heldCursor;
    while (true) {
      pass.checkInterrupted();
      final held = await _flags.heldPage(limit: _pageSize, afterName: heldCursor);
      if (held.isEmpty) {
        break;
      }
      heldCursor = held.last.name;

      // A loose file named after an asset follows it, like the rest. Only faces belong to none. A trashed asset can be
      // restored, so only locked or gone assets lose their files.
      String? ownerOf(OfflineHeldRow row) => row.assetId == row.name ? offlineAssetIdOf(row.name) : row.assetId;
      final ids = {for (final row in held) ?ownerOf(row)}.toList();
      final details = await _repository.detailsFor(ids);
      final unresolved = ids.where((id) => !details.containsKey(id)).toList();
      final locked = unresolved.isEmpty ? const <String>{} : await _repository.lockedIds(unresolved);
      final known = unresolved.isEmpty ? const <String>{} : await _repository.existingIds(unresolved);
      for (final row in held) {
        final owner = ownerOf(row);
        final asset = owner == null ? null : details[owner];
        final bool kept;
        if (owner == null) {
          kept = true;
        } else if (asset != null) {
          kept = !_isOldVersion(row.name, asset);
        } else {
          kept = known.contains(owner) && !locked.contains(owner);
        }
        if (kept) {
          keep.add(offlineNameHash(row.name));
        }
      }
    }

    // Plus everything a decision may still fetch, so a file landing mid-walk is not swept.
    final gone = <String>[];
    OfflineWantCursor? cursor;
    while (true) {
      pass.checkInterrupted();
      final wants = await _flags.page(after: cursor, limit: _pageSize);
      if (wants.isEmpty) {
        break;
      }
      cursor = wants.last.cursor;

      final details = await _repository.detailsFor(wants.map((want) => want.id).toList());
      for (final want in wants) {
        final asset = details[want.id];
        if (asset == null) {
          continue;
        }
        // The widest set a decision could ask for, so nothing the next pass would fetch again is swept.
        for (final file in offlineFilesFor(asset, want.quality, errand: true)) {
          keep.add(offlineNameHash(file.name));
        }
      }

      // Not in `detailsFor` can also mean trashed or locked, which is undoable. Only an asset with no row is gone.
      final missing = [
        for (final want in wants)
          if (!details.containsKey(want.id)) want.id,
      ];
      if (missing.isNotEmpty) {
        final existing = await _repository.existingIds(missing);
        gone.addAll(missing.where((id) => !existing.contains(id)));
      }
    }
    return (keep: keep, gone: gone);
  }

  /// Deletes the files of items moved to the locked folder, whose bytes must not sit outside the PIN gate. Each pass,
  /// rather than at the weekly integrity pass: being locked is something upstream says, so no complete sync is needed.
  Future<void> _dropLocked(_Pass _) async {
    // Arrivals still buffered are in `held` after this, so a download that raced the move is caught too.
    await _ledger.flush();
    final locked = await _flags.heldOfLocked();
    if (locked.isEmpty) {
      return;
    }
    final failed = await _ledger.remove(locked);
    final failures = failed > 0 ? ', $failed could not be deleted' : '';
    _log.info('Removed ${locked.length} file(s) of items moved to the locked folder$failures');
    _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
  }

  /// Records what browsing kept, as spares, or as library files when a selection wants them.
  ///
  /// A file is filed under a variant only if its name is exactly what [filesFor] gives that variant now; anything else
  /// (faces, full-size renditions, previews under an old thumbhash) is keyed by its own name, so it cannot displace the
  /// row of a file the mirror wants. Files of locked-folder assets are deleted on the spot.
  Future<void> _recordStored(List<(String, int)> stored) async {
    // Before any wait: a wipe meanwhile makes these files not ours to record.
    final ticket = _ledger.ticket();
    await _ready;

    final byAsset = <String, List<(String, int)>>{};
    final rows = <OfflineHeldRow>[];
    for (final (name, size) in stored) {
      final assetId = offlineAssetIdOf(name);
      if (assetId == null) {
        rows.add(_looseRow(name, size));
        continue;
      }
      (byAsset[assetId] ??= []).add((name, size));
    }

    final details = await _repository.detailsFor(byAsset.keys.toList());
    final unresolved = [
      for (final assetId in byAsset.keys)
        if (!details.containsKey(assetId)) assetId,
    ];
    final locked = unresolved.isEmpty ? const <String>{} : await _repository.lockedIds(unresolved);
    final refused = <String>[];
    for (final MapEntry(key: assetId, value: files) in byAsset.entries) {
      final asset = details[assetId];
      if (asset == null) {
        if (locked.contains(assetId)) {
          refused.addAll(files.map((file) => file.$1));
        } else {
          rows.addAll(files.map((file) => _looseRow(file.$1, file.$2)));
        }
        continue;
      }
      final known = {for (final file in offlineFilesFor(asset, kOfflineErrandQuality, errand: true)) file.name: file};
      for (final (name, size) in files) {
        final file = known[name];
        rows.add(
          file == null
              ? _looseRow(name, size)
              : OfflineHeldRow(name: name, assetId: assetId, variant: file.variant, token: file.token, size: size),
        );
      }
    }

    for (final row in rows) {
      _bufferHeld(row, ticket);
    }
    if (refused.isNotEmpty) {
      await _ledger.discard(refused, why: 'locked-folder');
      _log.fine('Dropped ${refused.length} file(s) of items the mirror may not keep');
    }
  }

  /// A thumbnail or preview of [asset] under another name than it has now: an older version, since an edit renames them.
  /// Whether it was recorded under the asset or under its own name.
  bool _isOldVersion(String name, OfflineAsset asset) {
    final variant = offlineVariantOfName(name);
    if (asset.thumbHash.isEmpty || (variant != OfflineVariant.thumbnail && variant != OfflineVariant.preview)) {
      return false;
    }
    return !offlineFilesFor(asset, kOfflineErrandQuality, errand: true).any((file) => file.name == name);
  }

  /// A kept file that is not a tracked variant: keyed by its own name and belonging to no asset, so it is a spare.
  OfflineHeldRow _looseRow(String name, int size) =>
      OfflineHeldRow(name: name, assetId: name, variant: offlineVariantOfName(name), token: 0, size: size);

  void _evictSoon() {
    if (_evictionPending) {
      return;
    }
    _evictionPending = true;
    unawaited(() async {
      try {
        await _exclusive(_evict);
      } catch (error, stack) {
        _log.warning('Eviction failed', error, stack);
      } finally {
        _evictionPending = false;
      }
    }());
  }

  /// Evicts spares, least recently used first, until the store is back under its ceiling. Never the library and never a
  /// pending *Save offline*; if that is not enough, downloading stops. The caller holds the pass lock.
  Future<void> _evict(_Pass pass) async {
    await _measureDevice();
    final target = _space.evictionTarget(_limit);
    if (target == null || _isUnderLimit()) {
      if (_status.isOverLimit) {
        _emit(_status.copyWith(isOverLimit: false));
      }
      return;
    }
    await _ledger.flush();

    var removed = 0;
    var freed = 0;

    while (_index.heldBytes > target) {
      // A wipe waiting for the lock removes everything anyway.
      try {
        pass.checkInterrupted();
      } on _PassInterrupted {
        return;
      }
      final batch = await _flags.evictionCandidates(bytes: _index.heldBytes - target);
      if (batch.isEmpty) {
        break;
      }

      final failed = await _ledger.remove(batch);
      if (failed > 0) {
        _log.warning('$failed evicted file(s) could not be deleted; the integrity pass will retry them');
      }
      removed += batch.length;
      freed += batch.fold(0, (sum, row) => sum + row.size);
    }

    if (removed > 0) {
      // A hand-saved item with no files left stops being wanted, or the next pass would fetch it back.
      await _flags.dropFetchedWithoutFiles();
      await _loadIndex();
      _log.info('Evicted $removed spare file(s), ${(freed / (1024 * 1024)).toStringAsFixed(1)} MB');
    }
    final full = !_isUnderLimit();
    if (removed > 0 || full != _status.isOverLimit) {
      _emit(_countsOn(_status).copyWith(isOverLimit: full, revision: removed == 0 ? null : _status.revision + 1));
    }
    if (!full && !_isPaused) {
      unawaited(_queue.topUp());
    }
  }

  /// Stops or resumes downloading without changing what is wanted. Persisted. Takes effect at once, even while a pass
  /// runs: the pass sees the queue was cleared and does not fill it again.
  Future<void> setPaused(bool value) async {
    await _setPaused(value);
    if (!value) {
      await sync();
    }
  }

  Future<void> _setPaused(bool value) async {
    await _settings.write(SettingsKey.offlinePaused, value);
    _emit(_status.copyWith(isPaused: value));

    if (value) {
      _stopDownloads();
    }
  }

  /// Cancels everything queued without recording a pause, for sign-out and constraint changes. Unlike [setPaused], it
  /// does not leave downloading off on the next launch. Does not wait for a running pass.
  Future<void> stopDownloads() async => _stopDownloads();

  void _stopDownloads() {
    _changes.invalidate();
    _queue.clear();
    _emit(_status.copyWith(queued: 0, pending: 0));
  }

  Future<void> retryFailed() async {
    await _flags.forgetFailures();
    _changes.invalidate();
    _emit(_status.copyWith(failed: 0));
    await sync();
  }

  /// Removes every stored file. [forgetSelection] also clears the selection and the decisions derived from it; signing
  /// out does not touch them otherwise.
  Future<void> deleteAll({bool forgetSelection = false}) async {
    // At once, rather than once the lock is free: a running pass gives it up at its next page.
    _interrupts++;
    _stopDownloads();
    await _exclusive((pass) async {
      await _ledger.wipe(
        forgetSelection: forgetSelection,
        // With the selection kept, pause so it is not fetched straight back; with it gone there is nothing to fetch.
        stop: forgetSelection ? () async => _stopDownloads() : () => _setPaused(true),
      );
      if (forgetSelection) {
        await _settings.write(SettingsKey.offlinePolicy, OfflinePolicy.empty.encode());
      }

      _emit(
        _countsOn(_status).copyWith(
          failed: 0,
          // They describe what the selection could not get, so they reset with it.
          unavailable: forgetSelection ? 0 : null,
          onDevice: forgetSelection ? 0 : null,
          revision: _status.revision + 1,
        ),
      );
    });
  }

  Future<void> dispose() async {
    _emitTimer?.cancel();
    _revisionTimer?.cancel();
    _checkTimer?.cancel();
    _queue.dispose();
    await _ledger.dispose();
    await _statusController.close();
  }
}
