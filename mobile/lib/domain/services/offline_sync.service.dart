/// immich-sync fork — keeps the blob store equal to what the user selected (FORK.md §3.3). Three passes of increasing
/// cost, because the frequent case must be nearly free: [check] is a few aggregates and runs on every resume, [sync]
/// pages the wanted list and queues what is missing, and [reclaim] walks the whole store on its own isolate, weekly or
/// on demand.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/utils/offline_index.dart';
import 'package:immich_mobile/domain/utils/offline_queue.dart';
import 'package:immich_mobile/infrastructure/repositories/offline.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_download.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/utils/async_mutex.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:immich_mobile/utils/offline_reclaim.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart' show AssetMediaSize;
import 'package:path/path.dart' as p;

/// Rows per page, and the missing files one [sync] looks for before stopping.
const _pageSize = 500;
const _missingBudget = 3000;

/// How long a burst of changes may go on postponing the pass it is asking for, and how long after the last of them the
/// pass runs when the burst does end.
const _checkMaxWait = Duration(seconds: 20);
const _checkDelay = Duration(seconds: 3);

/// How long a task may sit with the downloader before it is worth a line in the log. Long enough that a large video on
/// a slow link is not news, short enough to notice a task that will never finish.
///
/// Age alone never makes a task dead. One that has started is dead once it has said nothing — no start, no progress —
/// for this long. One that has not started is usually just waiting its turn behind the group's running slots, for as
/// long as those take, so it is dead only once the whole group has been silent this long: nothing started, moved or
/// finished. Counting from the hand-over instead cancelled every task queued behind eight slow videos, over and over.
const _stuckAfter = Duration(minutes: 15);

/// How long *this process* watches an already-old task before it is allowed to call it dead.
///
/// The age comes from the database and so survives a restart, which is the whole point of recording it; the evidence
/// that a task is moving — its progress callbacks — does not. On the first pass after a launch, a video that has been
/// downloading happily for twenty minutes is therefore old with nothing to show for it, and cancelling it would throw
/// away exactly the work that is hardest to redo. A running download reports within seconds, so waiting this long for
/// it to say something costs nothing and settles the question.
const _stuckSettle = Duration(minutes: 2);

/// Whether a task the downloader has held for at least [_stuckAfter] is dead, rather than slow or waiting its turn.
///
/// [lastSign] is when it last started or reported progress in this process, null if it has not; [groupMoved] is when
/// any of the mirror's tasks last started, moved or ended, null if none has; [watchingSince] is when this process first
/// saw it (see [_stuckSettle]).
@visibleForTesting
bool offlineTaskIsDead({
  required DateTime now,
  required DateTime? lastSign,
  required DateTime? groupMoved,
  required DateTime watchingSince,
}) {
  if (lastSign != null) {
    // It started, or was moving, and has stopped.
    return now.difference(lastSign) >= _stuckAfter;
  }
  // It has said nothing at all. That is what waiting for a slot looks like too, for as long as the running tasks take,
  // so it counts only while those are silent as well — and only once this process has given it long enough to speak
  // up. Without that grace a restart in the middle of a large download reads as silence and throws the file away.
  return offlineGroupSilent(now: now, groupMoved: groupMoved) && now.difference(watchingSince) >= _stuckSettle;
}

/// Whether nothing of the mirror's has started, moved or ended for [_stuckAfter] — what a deferred or orphaned queue
/// looks like, and a busy one never does.
@visibleForTesting
bool offlineGroupSilent({required DateTime now, required DateTime? groupMoved}) =>
    groupMoved == null || now.difference(groupMoved) >= _stuckAfter;

/// How long the store may go unverified. The pass costs a walk over every file and only catches what the incremental
/// paths cannot, so it is rare.
const _reclaimInterval = Duration(days: 7);

/// What the store leaves free on the device whatever the limit says, "No limit" included. Spares are evicted to keep
/// it, and downloading stops once only the library is left. Below about a gigabyte the system itself starts reclaiming
/// space and apps start failing to write.
const _freeSpaceFloor = 1024 * 1024 * 1024;

/// How far under the ceiling eviction goes, so a store sitting at its limit does not evict on every file that lands.
/// A twentieth of the ceiling, and never more than this.
const _evictionSlack = 256 * 1024 * 1024;

class OfflineSyncService {
  OfflineSyncService(this._repository, this._flags, this._downloads, this._settings) {
    _status = _status.copyWith(isPaused: _settings.appConfig.offlinePaused);
    _index.publish();
    _downloads.onFinished = onTaskFinished;
    _downloads.onProgress = onTaskProgress;
    _downloads.onStarted = onTaskStarted;
    // What the image path stores and serves, so browsing becomes spares and their last use is known (FORK.md §3.4).
    offlineListenForStoreActivity(_onStoreActivity);
    offlineOnRead = _noteRead;
    _queue = OfflineDownloadQueue(
      _downloads,
      _settings,
      onHeld: _bufferHeld,
      onChanged: () => _emitSoon(_queueCountsOn(_status)),
      onRefused: (refused) => _log.severe(
        'The downloader refused ${refused.length} file(s); they stay missing until the next pass: '
        '${refused.take(5).map((download) => '${download.assetId} ${download.file.variant.name}').join(', ')}',
      ),
      hasRoom: _isUnderLimit,
      isBackingUp: () => _isBackingUp?.call() ?? false,
    );
    _ready = _loadIndex();
  }

  final OfflineRepository _repository;
  final OfflineFlagsRepository _flags;
  final OfflineDownloadRepository _downloads;
  final SettingsRepository _settings;
  final _log = Logger('OfflineSyncService');

  /// Whether upstream's backup has work in hand, injected rather than read from a provider so this stays a domain
  /// service. The mirror hands nothing over while it is true (`offline_queue.dart`).
  bool Function()? _isBackingUp;
  void bindBackupActivity(bool Function() isBackingUp) => _isBackingUp = isBackingUp;

  /// Something wrote to the camera-roll table, or to one of upstream's own. See [_upstreamMoved].
  void noteLocalAssetsChanged() {
    _localMoved = true;
    _localWrites++;
  }

  void noteUpstreamChanged() {
    _upstreamMoved = true;
    _upstreamWrites++;
  }

  /// A write to upstream's tables, reported the moment it happens rather than once a burst has settled. Only counted:
  /// asking for a pass stays with [noteUpstreamChanged], which the watcher calls once the writing stops.
  void noteUpstreamWrite() => _upstreamWrites++;

  final _index = OfflineIndex();

  /// What to fetch next, and how much at once (`offline_queue.dart`).
  late final OfflineDownloadQueue _queue;
  late final Future<void> _ready;

  final _statusController = StreamController<OfflineStatus>.broadcast();
  OfflineStatus _status = const OfflineStatus();

  /// Passes run one at a time, through upstream's own mutex. A flag instead would let a decision from the UI interleave
  /// with `reclaim`, and let `setPaused(false)` do nothing because something else was running.
  final _passes = AsyncMutex();

  /// Upstream, the fork's decisions and the viewer setting that names video files, as of the last completed pass.
  /// Whether anything upstream has been written since the last pass read it, and the same for the camera roll.
  ///
  /// These replaced a fingerprint — asset count, album-link count, `MAX(updated_at)` — and the reason is that a
  /// fingerprint of column values cannot see an asset row change **in place**. `remote_asset_entity.updated_at` is fed
  /// from `fileModifiedAt` (`sync_stream.repository.dart`), so it is a property of the photograph and not a clock:
  /// editing an asset, reverting the edit, favouriting or trashing it move none of the three components. The mirror
  /// therefore did not notice an edit being undone, because nothing it was watching had changed — and the unfiltered
  /// `COUNT(*)` could not see a trashing either.
  ///
  /// A write is what a pass needs to hear about, so a write is what it is told. Drift already reports one per table,
  /// which is cheaper than the fingerprint it replaces: `updated_at` is unindexed, so `MAX` over it was a full scan of
  /// the widest table in the schema, paid on every resume.
  bool _upstreamMoved = true;

  /// How many upstream writes this process has heard of. What the integrity pass compares across its walk to know
  /// whether the table moved underneath it.
  ///
  /// [_upstreamMoved] cannot answer that: it is a flag, and it is already set whenever a pass has not settled — which is
  /// every launch, and every pass that stopped at its budget. A write during the walk then sets it to what it already
  /// was, and a comparison of the two reads "nothing moved" while the asset table is half rewritten. A count cannot
  /// stand still while something is writing.
  int _upstreamWrites = 0;
  int? _flagRevision;
  String? _syncedVideoForm;

  /// Something wrote to the camera-roll table and no pass has read it back yet.
  ///
  /// The fingerprint cannot stand in for this and never could. `localCount` is a **row count**, and the change that
  /// matters most here moves no rows: hashing fills a checksum in on a local asset that was already there, and a
  /// checksum match is the entire definition of `localCopyUsable` (`offline.repository.dart`). So the sequence that
  /// happens on every phone, every day — take a photo, it is hashed, it is uploaded — leaves the mirror believing the
  /// item has no local copy, because the pass that could have learned otherwise was told nothing had changed. The
  /// consequences are the visible ones: a full-size copy fetched for a photo the camera roll already holds, and a tile
  /// drawing a full white bar over it as though a setting maintained the thing.
  ///
  /// Set by the debounced watcher in `offline.provider.dart`, cleared by a pass that walked every wanted row and so
  /// re-read the live answer for all of them.
  bool _localMoved = true;

  /// How many times [_localMoved] has been raised, for the same reason as [_upstreamWrites]: a pass may only lower the
  /// flag if nobody raised it again while the pass was reading.
  int _localWrites = 0;

  /// Completed files waiting to be written down. Batched: a mirror in progress finishes several a second, each
  /// otherwise a transaction and a channel hop.
  final _heldBuffer = <OfflineHeldRow>[];
  Timer? _heldTimer;

  /// Files served since the last write, whose `used_at` moves with it. A set: a timeline scrolled back and forth reads
  /// the same thumbnails many times over.
  final _readBuffer = <String>{};

  /// Set while an eviction is queued or running, so a burst of writes asks for one.
  bool _evictionPending = false;

  /// The most the device can give the store, as of the last time it was asked: what the store holds, plus the free
  /// space, minus [_freeSpaceFloor]. Null until asked, and where the platform cannot say.
  int? _deviceCeiling;

  /// How long to wait before writing the buffer again after a write failed; null while writes succeed. Doubles per
  /// failure up to [_heldRetryLimit], so a disk that stays full costs a line a minute rather than one every two seconds.
  Duration? _heldRetry;
  static const _heldRetryFirst = Duration(seconds: 2);
  static const _heldRetryLimit = Duration(minutes: 1);

  /// Bumped by [deleteAll], at its start and again once the files are gone. A completed download measured, or a batch
  /// written, across a wipe belongs to a store that no longer exists, and recording it would list files that are gone.
  int _storeGeneration = 0;
  bool _reclaiming = false;

  Timer? _emitTimer;
  Timer? _revisionTimer;
  Timer? _checkTimer;

  /// When the pass now pending was first asked for, so a burst cannot postpone it indefinitely (see [checkSoon]).
  DateTime? _checkAskedAt;

  /// When each outstanding task was first seen, so a pass can tell a long download from a stuck one. Read back from the
  /// database on the first pass of a process — see [OfflineFlagsRepository.outstandingSince] for why it has to be.
  ///
  /// Empty but *modifiable*: a task can reach a final state before the first pass replaces this, and [_onTaskFinished]
  /// removes from it. `const {}` is unmodifiable and throws there.
  Map<String, DateTime> _outstandingSince = {};
  bool _loadedOutstandingSince = false;

  /// When *this process* first saw each outstanding task, which is a different question from how old it is — see
  /// [_stuckSettle].
  final _watchingSince = <String, DateTime>{};

  /// How far the running files have got, and when they last said so: a start counts as 0%, and only full-size copies
  /// report progress after it. Entries go when a task ends, so this holds about as many as the group runs at once. It
  /// is what separates a slow download from one that has stopped moving.
  final _progress = <String, ({double fraction, DateTime at})>{};

  /// When any of the mirror's tasks last started, moved or ended in this process — null until one does. A task still
  /// waiting its turn is only suspect while this is old too (see [_stuckAfter]).
  DateTime? _lastMovement;

  /// Tasks [_reportOutstanding] cancelled, until their cancellation lands. Unlike every other cancellation the mirror
  /// makes, these are files no pass has planned — the walk skipped them as in flight — so their callback has to ask
  /// for the pass that fetches them again.
  final _reaped = <String>{};

  Stream<OfflineStatus> get status => _statusController.stream;
  OfflineStatus get current => _status;

  /// What is on this device for an asset, with no I/O.
  OfflineAvailability availabilityOf(String assetId) => _index.availabilityOf(assetId);

  /// The rung recorded for an asset, for the troubleshooting screen: what the mirror believes it was asked to keep.
  OfflineQuality wantedOf(String assetId) => _index.wantedOf(assetId);

  /// Whether the camera roll holds a usable original, so the mirror wants nothing beyond the preview (§3.2). What the
  /// tile badge asks, because the asset it is drawing cannot answer it on every screen.
  bool localCopyOf(String assetId) => _index.localCopyOf(assetId);

  /// Whether *Save offline* is still outstanding for an asset, which overrides [localCopyOf]: the errand asks for this
  /// app's own copy however much of the item the camera roll holds.
  bool errandOf(String assetId) => _index.errandOf(assetId);

  /// The three sections a tile's bar is drawn from — thumbnail, preview and full copy (FORK.md §3.6).
  OfflineBar barOf(String assetId) => _index.barOf(assetId);

  bool get _isPaused => _settings.appConfig.offlinePaused;

  /// The most the store may hold: the user's limit, and never so much that the device runs short. Null for no ceiling at
  /// all, which is "No limit" on a platform that cannot report free space.
  int? get _ceiling {
    final limit = _settings.appConfig.offlineStorageLimit;
    final device = _deviceCeiling;
    if (limit <= 0) {
      return device;
    }
    return device == null ? limit : math.min(limit, device);
  }

  /// Whether the store may still grow. Spares are evicted to make room before this says no, so once it does, what is
  /// left is the library.
  bool _isUnderLimit() {
    final ceiling = _ceiling;
    return ceiling == null || _index.heldBytes < ceiling;
  }

  /// Asks the device how much room is left. Free space moves with everything else on the phone, so this is asked again
  /// before every decision that depends on it rather than remembered.
  Future<void> _measureDevice() async {
    final free = await offlineFreeSpace();
    _deviceCeiling = free == null ? null : math.max(0, _index.heldBytes + free - _freeSpaceFloor);
  }

  Future<T> _exclusive<T>(Future<T> Function() action) => _passes.run(action);

  void _emit(OfflineStatus next) {
    _status = next;
    if (!_statusController.isClosed) {
      _statusController.add(next);
    }
  }

  /// Coalesced emit, for updates arriving at download speed.
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

  /// At most one badge refresh every few seconds, however fast files land.
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
      final rows = await _flags.loadIndex();
      _index.load(rows, heldBytes: await _flags.heldBytes());
      _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
    } catch (error, stackTrace) {
      _log.severe('Could not read what is stored offline', error, stackTrace);
    }
  }

  OfflineStatus _countsOn(OfflineStatus status) => status.copyWith(
    wantedAssets: _index.wantedAssets,
    wanted: _index.wantedFiles,
    held: _index.heldFiles,
    bytes: _index.heldBytes,
  );

  /// What the queue holds, in the two figures it has to be told apart by: files the downloader has, and files merely
  /// planned. Always written together — reporting one without the other is what let a plan read as progress.
  OfflineStatus _queueCountsOn(OfflineStatus status) => status.copyWith(queued: _queue.queued, pending: _queue.pending);

  // --------------------------------------------------------------------------- The selection, and deriving from it

  OfflinePolicy get policy => OfflinePolicy.decode(_settings.appConfig.offlinePolicy);

  /// Applies [change] to the selection and re-derives everything it covers.
  ///
  /// There is no scope and nothing is deferred. Re-deriving is one statement now (`OfflineFlagsRepository.derive`), so
  /// working out *which* albums a change touched costs more than acting on all of them — and every mechanism that
  /// existed to narrow the work was also a way for it to be missed. What went with the narrowing: the per-album scopes
  /// and the generation counter that decided which pass owned them, the record of work handed back by a derivation
  /// that failed, the remembered album sizes that detected a changed album, and the walk that re-derived one album at
  /// a time.
  Future<void> applyPolicy(OfflinePolicy Function(OfflinePolicy current) change) async {
    await _ready;
    await _exclusive(() async {
      final previous = policy;
      final next = change(previous);
      if (next == previous) {
        // A menu re-picking what it showed. Deriving would be inert but still scan the library.
        return;
      }
      await _settings.write(SettingsKey.offlinePolicy, next.encode());
      await _rederive(next);
    });
    await _afterImperativeChange();
  }

  /// Re-derives every decision, and tells the screens if anything moved.
  ///
  /// Stamped where the change is recorded rather than where a file is fetched, so the queue reflects the order the
  /// instructions were given in (FORK.md §3.3).
  Future<void> _rederive([OfflinePolicy? selection]) async {
    final changed = await _flags.derive(selection ?? policy, DateTime.now());
    if (changed == 0) {
      return;
    }
    // The index is rebuilt rather than patched row by row. A bulk statement has no per-row hook to patch from, and
    // reading back what it wrote is both simpler and the only version that cannot drift from it — which is the whole
    // reason the counters were wrong before. It costs a query, and only when something actually moved.
    await _loadIndex();
    _log.info('Re-derived the selection; $changed decision(s) moved');
    // With the revision, not just the counts: a decision is the moment a tile starts having something to say — an
    // empty track, for a photo now on its way — and the badge redraws on the revision alone.
    _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
  }

  /// Drops albums upstream no longer has from the selection.
  ///
  /// The selection names albums by id, so a deleted one would otherwise sit in it for ever — invisible, since the
  /// screen lists albums upstream has, and load-bearing, since an *excluded* album goes on suppressing its photos.
  Future<void> _forgetVanishedAlbums() async {
    final named = {...policy.albums.keys, ...policy.excluded};
    if (named.isEmpty) {
      return;
    }
    final alive = await _repository.existingAlbumIds(named);
    final vanished = named.difference(alive);
    if (vanished.isEmpty) {
      return;
    }

    final next = vanished.fold(policy, (current, id) => current.withAlbum(id, OfflineAlbumState.notIncluded));
    await _settings.write(SettingsKey.offlinePolicy, next.encode());
    await _rederive(next);
    _log.info('Forgot ${vanished.length} album(s) upstream no longer has');
  }

  ({int wanted, int available}) progressOf(Iterable<String> assetIds) {
    var wanted = 0;
    var available = 0;
    for (final id in assetIds) {
      if (_index.wantedOf(id).isWanted) {
        wanted++;
        // Against what *this* item's rung asks for, so a library at previews does not read as done once every
        // thumbnail has landed — which, the queue fetching all thumbnails first, it would for most of the sync.
        if (_index.availabilityOf(id).covers(_index.wantedOf(id).availableAt)) {
          available++;
        }
      }
    }
    return (wanted: wanted, available: available);
  }

  /// "Save offline" on selected items: a one-way errand rather than a preference, kept as a cache until [freeUpSpace]
  /// takes it back (FORK.md §3.2).
  Future<void> fetchForOffline(Iterable<String> assetIds) async {
    await _ready;
    final ids = assetIds.toList();
    final details = await _repository.detailsFor(ids);
    // Whether a selection already covers each item, which decides only what kind of row this writes. Asked of the
    // policy rather than the index, which does not record it: an item fetched by hand once is *wanted* there, and
    // reading that back would turn a spare into part of the library on the second fetch.
    final albums = await _repository.albumsOf(ids);

    await _exclusive(() async {
      // Read under the lock, so a selection change landing between the tap and here is the one this writes against.
      final policy = this.policy;
      final now = DateTime.now();
      final rows = <OfflineFlagRow>[];
      for (final asset in details.values) {
        final selected = policy.resolve(albums[asset.id] ?? const []);
        // Stamped even when nothing about the decision changes. The errand is "get me these now", so the row it writes
        // is what puts them in front of whatever bulk work is running — and an item the settings already keep whole has
        // nothing else to change, which is exactly where skipping the write would leave the errand inert.
        rows.add(
          OfflineFlagRow(
            id: asset.id,
            // **What the selection maintains**, and not what this errand is about to fetch. The two are different
            // questions and this column can only answer one: it is what `_unselectedOver` reads to decide whether a
            // held file is a spare. Writing the errand's own appetite here told the reclaim bands that a library kept
            // at previews maintains full-size copies, so a hand-saved original counted as persistent library, sat in
            // the band that is locked until every spare above it is going, and could never be freed at all. The
            // errand's wider appetite lives in its own mark (`wanted.pinned`), where `filesFor` reads it.
            quality: selected ?? kOfflineErrandQuality,
            createdAt: asset.createdAt,
            touchedAt: now,
            // A selection-derived row when one covers it: marking it a cache would make every file it has reclaimable,
            // the preview its album still asks for included.
            onDemand: selected == null,
          ),
        );
      }

      await _flags.set(rows);
      // The copies already here count as just used, so a save protects them from eviction for as long as anything newer
      // can be evicted first. The ones on their way are stamped as they land.
      await _flags.touchAssets(rows.map((row) => row.id), now);
      // "Get me these now" is a claim on the next few minutes of bandwidth, not a preference, so it is marked as such:
      // the queue puts an errand before every standing decision, however recent that decision is (FORK.md §3.3). The
      // mark cannot be read off the row above — `on_demand` is false whenever a selection also covers the item, which is
      // exactly the case where the errand still has to jump the queue.
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
          // A row nothing else selects is a spare in its entirety, and the bar has to say so rather than drawing the
          // errand's copies as library.
          onDemand: row.onDemand,
        );
      }
      // The action's label follows what is stored, so it has to be told now
      // rather than at the next download's coalesced bump.
      _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
    });

    await _afterImperativeChange();
  }

  /// Undoes [fetchForOffline] for these items: whatever the errand added on top of the selection goes, and what the
  /// selection asks for stays.
  Future<void> releaseOnDemand(Iterable<String> assetIds) async {
    await _ready;
    final ids = assetIds.toList();
    final details = await _repository.detailsFor(ids);
    final albums = await _repository.albumsOf(ids);

    await _exclusive(() async {
      // Under the lock, for the same reason as in [fetchForOffline].
      final policy = this.policy;
      final now = DateTime.now();
      final rows = <OfflineFlagRow>[];
      final forgotten = <String>[];

      for (final id in ids) {
        final asset = details[id];
        final quality = asset == null ? null : policy.resolve(albums[id] ?? const []);
        if (quality == null) {
          // Nothing selects it any more, so there is no decision left to record;
          // its files become reclaimable in the same breath.
          forgotten.add(id);
          continue;
        }
        rows.add(OfflineFlagRow(id: id, quality: quality, createdAt: asset!.createdAt, touchedAt: now));
      }

      await _flags.set(rows);
      await _flags.forget(forgotten);
      // Taking the errand back takes its place in the queue with it, for the rows a selection still keeps. `forget`
      // clears the rest as part of dropping the decision.
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
  }

  /// How the store's bytes divide between what a selection maintains and the spares, for the overview on the offline
  /// screen.
  Future<OfflineStorage> storage() => _flags.storage();

  /// The most the app may hold in total, or zero for no limit. Lowering it evicts spares, least recently used first,
  /// and stops downloading if the library alone is over it; it never deletes the library. Raising it lets downloading
  /// continue at once.
  Future<void> setStorageLimit(int bytes) async {
    await _settings.write(SettingsKey.offlineStorageLimit, bytes);
    await _ready;
    await _exclusive(_evict);
    if (_isUnderLimit()) {
      await sync();
    }
  }

  /// What "free up space" would take back. [assetIds] narrows it to one album, [kind] to one half of each asset.
  Future<OfflineReclaimPlan> reclaimPlan({
    Iterable<String>? assetIds,
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) => _flags.reclaimPlan(assetIds: assetIds, what: what);

  /// What each ticked cell of a choice would actually give up — a previews cell gives up less than it holds while the
  /// copies holding it up are staying.
  Future<Map<OfflineReclaimCell, int>> reclaimBytesByCell(OfflineReclaim what) => _flags.reclaimBytesByCell(what);

  /// Reclaimable bytes per asset, for the rows that report what their own change left behind.
  Future<Map<String, int>> spareBytesByAsset() => _flags.reclaimableBytesByAsset();

  /// The one control that takes bytes off the device.
  Future<void> freeUpSpace({Iterable<String>? assetIds, OfflineReclaim what = OfflineReclaim.notMaintained}) async {
    await _ready;
    await _flushHeld();

    await _exclusive(() async {
      if (what.pauses) {
        await _setPaused(true);
      }
      final root = await offlineStoreRoot();
      String? cursor;
      var freed = 0;

      while (true) {
        final files = assetIds == null
            ? await _flags.reclaimableFiles(limit: _pageSize, afterName: cursor, what: what)
            : await _flags.reclaimableFilesFor(assetIds, what: what);
        if (files.isEmpty) {
          break;
        }
        cursor = files.last.name;

        // A page at a time on another isolate: the deletes are the whole cost of
        // this pass, and doing them here froze the screen that asked for them.
        final deleted = await offlineDeletePaths([for (final file in files) offlinePinnedPath(root, file.name)]);
        if (deleted.failed > 0) {
          _log.warning('${deleted.failed} file(s) could not be deleted; the integrity pass will retry them');
        }
        freed += files.length;
        for (final file in files) {
          _index.dropHeld(file.assetId, file.variant, file.size);
        }
        await _flags.dropHeld(files.map((file) => file.name));
        // Coarse, but it is the difference between a frozen app and a moving one.
        _emit(_countsOn(_status));
        if (assetIds != null) {
          // A scope is bounded by its album and comes back whole, so there is no
          // next page to ask for.
          break;
        }
      }

      // The rows that only existed to fetch a cache have nothing left to describe.
      await _flags.dropFetchedWithoutFiles();
      // The native index still vouches for every name just deleted, and each stale entry costs a failed `open` on the
      // image path before it falls through to the network. One rebuild is cheaper than paying for all of them, which
      // is the same trade `_reclaim` makes after a sweep.
      if (freed > 0) {
        await offlineForgetIndex();
      }
      await _loadIndex();
      _log.info('Freed $freed file(s)');
      _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
    });

    // Room was the reason downloading stopped, so making room has to start it again — and the limit is only re-read by
    // a pass.
    await _afterImperativeChange();
  }

  /// Looks for what the change implies, and never resumes downloading.
  Future<void> _afterImperativeChange() async {
    _upstreamMoved = true;
    await sync();
  }

  // --------------------------------------------------------------------------- Passes

  /// [check], coalesced, for the events that say the remote side of the database moved.
  ///
  /// Upstream applies server state in bursts — a websocket batch is many assets — so one pass a few seconds after the
  /// **last** event is the right cost. Without it the mirror learns only on resume: a photo taken and uploaded while
  /// the app stays open sits unmirrored, and so does an album deleted on the server.
  ///
  /// The timer restarts on every event rather than ignoring events while one is pending. Ignoring them made this fire
  /// every three seconds for as long as the burst lasted, which on a first sync is a check against a table upstream is
  /// still writing — the one moment the timeline is trying to get an uninterrupted read of its own. A burst now costs
  /// one pass at the end of it, which is what the paragraph above always claimed.
  ///
  /// But never later than [_checkMaxWait] after the first event asked for it. A restarting timer collapses a burst
  /// only if the burst *ends*: a backup uploading photo after photo is a remote change per photo, and each one pushed
  /// the pass a further three seconds out, so the mirror could go the whole upload without looking once. Two photos
  /// taken together would come back as one mirrored and one not, until something else happened to wake a pass.
  void checkSoon() {
    final askedAt = _checkAskedAt ??= DateTime.now();
    final remaining = _checkMaxWait - DateTime.now().difference(askedAt);
    _checkTimer?.cancel();
    _checkTimer = Timer(remaining < _checkDelay ? (remaining.isNegative ? Duration.zero : remaining) : _checkDelay, () {
      _checkAskedAt = null;
      unawaited(check());
    });
  }

  /// The cheap pass: stop unless something moved, and otherwise re-derive and look for what is missing.
  ///
  /// The gate is a fingerprint of upstream, and everything past it is now affordable enough to run unconditionally
  /// when it opens: one statement re-derives every decision, and the walk that finds missing files follows. There is
  /// no longer a watermark to advance, a recent window to re-scan or a set of changed albums to work out — all three
  /// existed only to avoid a derivation that cost a page-by-page walk of the library, and it no longer does.
  Future<void> check({bool download = true}) async {
    await _ready;
    await _check(download: download);
  }

  Future<void> _check({bool download = true}) async {
    await _exclusive(() async {
      try {
        if (await _repository.assetCount() == 0) {
          return;
        }

        // A queue that still has work in it is not upstream's to report either. Nothing changing upstream is a reason to skip *looking for more*,
        // never a reason to skip driving what was already found: hand-overs are topped up by the callback of the task
        // that finished, so a task the downloader never reports on leaves the queue parked with nothing to restart it,
        // and the count beside "Downloading" going on describing it. `_sync` is what re-reads the plugin's own list,
        // cancels what has stopped moving and hands over again — and it is cheap to reach here, because passes are
        // asked for by changes and resumes rather than by downloading, so a healthy queue is not paying for this.
        //
        // Nor is a camera-roll write ([_localMoved]), which the fingerprint sees only in part — and which decides
        // whether the mirror owes an item a full-size copy at all, so a gate that closes over it is a gate that keeps
        // the wrong answer.
        if (!_upstreamMoved &&
            !_localMoved &&
            _queue.isIdle &&
            _flags.revision == _flagRevision &&
            offlineVideoForm() == _syncedVideoForm &&
            _status.lastError == null) {
          _log.fine('Nothing changed since the last pass');
          return;
        }

        await _forgetVanishedAlbums();
        await _rederive();
        await _sync(download: download);
      } catch (error, stackTrace) {
        _log.warning('Change check failed', error, stackTrace);
      }
    });
  }

  /// The middle pass: find missing files and queue them. Never deletes.
  Future<void> sync({bool download = true}) async {
    await _ready;
    await _exclusive(() => _sync(download: download));
  }

  Future<void> _sync({required bool download}) async {
    _emit(_status.copyWith(isWorking: true, clearError: true));

    try {
      final flagRevision = _flags.revision;
      // Claimed, not cleared: a write arriving *during* this pass is not one this pass read, so clearing the flags at
      // the end would swallow it. Only what was seen here is given up.
      //
      // Counted, not compared: the flags are usually already set when a pass begins, so a write during it would leave
      // them exactly as they were and look like no write at all (see [_upstreamWrites]).
      final localMoved = _localMoved;
      final localWrites = _localWrites;
      final upstreamWrites = _upstreamWrites;

      if (await _repository.assetCount() == 0 && _index.wantedAssets > 0) {
        // Photos are wanted and upstream has none: a database mid-repopulation
        // after a fresh install, a sync reset or a sign-out, not an instruction.
        _log.info('No assets known yet; leaving the mirror untouched');
        return;
      }

      // Before anything decides whether there is room: free space moves with everything else on the phone. Over the
      // ceiling, spares make room before the queue is told there is none.
      await _measureDevice();
      if (!_isUnderLimit()) {
        await _evict();
      }
      final held = await _downloads.outstanding();

      // Bring what the downloader is holding back down to the window before deciding anything else. Its queue outlives
      // the process and it never re-orders it, so whatever an older pass — or the build before an update — handed over
      // would otherwise run ahead of everything this pass is about to learn.
      final overWindow = _queue.excess([for (final task in held) (id: task.taskId, priority: task.priority)]).toSet();
      if (overWindow.isNotEmpty) {
        _log.info('Handing back ${overWindow.length} queued download(s) to make room for what comes first');
      }
      // And whatever is still presenting a token from before the last sign-in, which can only ever come back 401. They
      // are queued again below the moment their cancellation lands, this time with the token the app holds now.
      final staleAuth = {
        for (final task in held)
          if (!_downloads.carriesCurrentAuth(task)) task.taskId,
      };
      if (staleAuth.isNotEmpty) {
        _log.info('Handing back ${staleAuth.length} queued download(s) still carrying an old sign-in');
      }
      final excess = {...overWindow, ...staleAuth};
      if (excess.isNotEmpty) {
        await _downloads.cancel(excess);
      }

      // Every id the downloader was holding, the ones just cancelled included: cancelling is asynchronous and the task
      // id is the file name, so re-enqueueing one of those names in this pass would race its own cancellation. They are
      // skipped here and left to the next pass — which is why a pass that cancelled anything refuses to call itself
      // settled below, and so leaves the fingerprint null for the next wake-up to act on.
      final inFlight = held.map((task) => task.taskId).toSet();
      final outstanding = [
        for (final task in held)
          if (!excess.contains(task.taskId)) task,
      ];
      final abandoned = await _flags.abandoned();
      final errands = await _flags.errands();
      // Everything the downloader is holding, the cancellations included: each of those still reports a final state, and
      // a count that had already written them off would be decremented twice and let the window overrun.
      _queue.resetOutstanding(held.length, fullSize: held.where(_isFullSizeTask).length);
      final reaped = await _reportOutstanding(outstanding);

      // Built aside and swapped in at the end: downloads complete throughout a
      // pass and top the queue up outside the lock this pass holds.
      final found = <OfflineMissingFile>[];
      final satisfiedErrands = <String>{};
      final localCopyMoved = <String, bool>{};
      final walk = await _collectMissing(
        found,
        inFlight: inFlight,
        abandoned: abandoned,
        errands: errands,
        satisfiedErrands: satisfiedErrands,
        localCopyMoved: localCopyMoved,
      );

      // Items the camera roll has gained or lost since the index last read it.
      //
      // Nothing about the camera roll is stored any more — the bands and the walk both ask it directly (§3.2) — but the
      // badge cannot: it draws once per visible tile per frame and has no `ref` to await a query on, so the index keeps
      // a copy and this is what keeps that copy current. It is the last cache of an upstream fact left in the fork, and
      // the only one whose refresh is not a re-read of the row it describes, so it has to be maintained by hand here.
      //
      // The visible fault when it is not: *Remove from device* on a photo whose full-size copy the mirror holds should
      // turn the tile's bar from "half maintained, half spare" into one full-length maintained bar — the copy stops
      // being a duplicate of a camera-roll original the moment that original goes — and instead the tile keeps drawing
      // the split until something else reloads the index.
      if (localCopyMoved.isNotEmpty) {
        localCopyMoved.forEach((id, localCopy) => _index.noteLocalCopy(id, localCopy: localCopy));
        _emit(_status.copyWith(revision: _status.revision + 1));
        _log.info('${localCopyMoved.length} item(s) changed hands with the camera roll');
      }

      // The mark is what puts these files in front of the bulk work, so it goes as soon as they are here — otherwise a
      // finished errand keeps outranking a selection the user made afterwards.
      if (satisfiedErrands.isNotEmpty) {
        await _flags.dropErrands(satisfiedErrands);
        // The badge draws the errand's wider target, so letting the mark go changes what a tile says even when no file
        // moved — an errand satisfied by copies that were already here moves nothing else at all.
        for (final id in satisfiedErrands) {
          _index.noteErrand(id, errand: false);
        }
        _emit(_status.copyWith(revision: _status.revision + 1));
        _log.fine('${satisfiedErrands.length} errand(s) complete');
      }

      final complete = walk.complete;
      var unavailable = walk.unavailable;

      // A decision about a photo the server no longer has is stale rather than blocked, so it goes now instead of
      // waiting for the integrity pass a week later — which would hold the progress line short for days over photos
      // deleted from another device, with nothing on screen able to fix it.
      if (walk.walkedAll && walk.unresolved.isNotEmpty) {
        final known = await _repository.existingIds(walk.unresolved);
        // Hidden ones go the same way, though upstream still has a row: that is the video half of a Live Photo, which is
        // now fetched as a file of the photo instead, so a decision about it on its own is stale rather than blocked.
        // Without this, rows written before that changed sit in the "cannot be downloaded" count for good.
        final hidden = await _repository.hiddenIds(walk.unresolved);
        final gone = [
          for (final id in walk.unresolved)
            if (!known.contains(id) || hidden.contains(id)) id,
        ];
        if (gone.isNotEmpty) {
          for (final id in gone) {
            unavailable -= _index.wantedFilesOf(id);
          }
          await _flags.forget(gone);
          await _loadIndex();
          _log.info('Forgot ${gone.length} decision(s) about items the mirror no longer keeps on their own');
        }
      }

      // The pages arrive in `wanted` order, which is per asset; the queue puts them in the order they should be
      // fetched.
      //
      // Only a pass allowed to download may do this. A read-only pass — what opening the offline screen asks for, and
      // what a resume that could not reach the server gets — is here for the *figures*; loading its findings into the
      // queue and then not handing any of them over leaves a plan with nothing driving it, which is a queue that has to
      // be shaken by hand before it moves again.
      if (download) {
        _queue.replace(found);
      }

      // Every reason the queue is holding still comes from the queue itself, so the line cannot claim the mirror is
      // running while it is not: a pass that finds work, hands none over and says nothing reads exactly like a pass that
      // found nothing to do.
      final stopped = _queue.stoppedBecause;
      _log.info(
        'Pass: ${found.length} missing found, ${inFlight.length} with the downloader, ${abandoned.length} given up on'
        '${complete ? ', whole list read' : ', stopped at the budget'}'
        '${download ? '' : ', figures only'}'
        '${stopped == null ? '' : ', $stopped'}',
      );

      _emit(
        _queueCountsOn(_countsOn(_status)).copyWith(
          failed: await _flags.abandonedCount(),
          // Only a pass that read every row counted every one of them; a pass that stopped at its budget would report
          // a fraction of the figure and move the progress line for no reason.
          unavailable: walk.walkedAll ? unavailable : null,
          onDevice: walk.walkedAll ? walk.onDevice : null,
        ),
      );

      // Only a pass that reached the end saw the whole list, and only one allowed to enqueue acted on it. A pass that
      // merely looked must not silence the next one.
      //
      // Nor may a pass that *cancelled* something. The files behind those tasks were skipped above as in flight, so
      // this pass planned nothing for them, and the callback each cancellation produces cannot make up for it: it only
      // asks for another pass when something is already known to have moved. Marking it read here would therefore
      // announce that everything is accounted for while a handful of files have quietly fallen out of the plan — which
      // is the shape of "one of the two photos I took came back and the other did not".
      //
      // Nothing may be marked as read that a write has overtaken. Everything between claiming the flags and here is a
      // decision made from a snapshot, so a row that changed while the pass ran is one the pass could not have acted
      // on — and calling it seen is how a photo uploaded seconds earlier ends up with its preview never fetched: the
      // thumbhash it was waiting for landed mid-pass, and the next check was told nothing had happened since.
      final settled = complete && download && excess.isEmpty && !reaped && _upstreamWrites == upstreamWrites;
      // Answered by the walk rather than by the hand-over, so a read-only pass settles it too: the flag asks whether
      // anything has re-read the camera roll since it was written, and a walk that reached the end of the wanted list
      // did exactly that for every row in it — no download required.
      if (walk.walkedAll && localMoved && _localWrites == localWrites) {
        _localMoved = false;
      }

      if (settled) {
        _upstreamMoved = false;
        _flagRevision = flagRevision;
        _syncedVideoForm = offlineVideoForm();
      } else {
        // Left standing, so the gate opens again. The work this pass could not finish would otherwise wait for an
        // unrelated event, and on a quiet phone that is never.
        _upstreamMoved = true;
      }

      _emit(_status.copyWith(isOverLimit: !_isUnderLimit()));

      if (download) {
        await _queue.topUp();

        // Nothing was enqueued, so no completion callback will come back to ask for the next page — the whole story
        // after a rename, where thousands of files are re-claimed with nothing downloading to drive it.
        if (!complete && !_isPaused && _queue.isIdle) {
          unawaited(sync());
        }
      }
    } catch (error, stackTrace) {
      _log.warning('Sync failed', error, stackTrace);
      _emit(_status.copyWith(lastError: error.toString()));
    } finally {
      _emit(_status.copyWith(isWorking: false));
    }
  }

  /// One walk of the wanted list, adding what is missing to [into].
  ///
  /// A bounded pass sees at most [_missingBudget] files, so *which* ones it sees is the ordering — sorting the batch
  /// afterwards cannot fix a batch that is already the wrong three thousand files. It is spent in the queue's own order
  /// (FORK.md §3.3):
  ///
  /// - **errands** get theirs first and are never crowded out: they are what the user is waiting on, and there are only
  ///   ever as many as were tapped;
  /// - then **one decision at a time**, newest first, because rows arrive in that order — so ticking an album during a
  ///   library-wide sync spends the next budget on that album rather than on the backlog;
  /// - and within a decision the **cheap half before the full-size one**, or a library switched to full quality fills
  ///   the budget with the newest items' originals while older items have no preview at all.
  Future<({bool walkedAll, bool complete, int unavailable, int onDevice, List<String> unresolved})> _collectMissing(
    List<OfflineMissingFile> into, {
    required Set<String> inFlight,
    required Set<String> abandoned,
    required Set<String> errands,
    required Set<String> satisfiedErrands,
    required Map<String, bool> localCopyMoved,
  }) async {
    final chaseBase = await _flags.hasMissingBase();

    // Held aside from the decisions entirely, and given the front of the batch at the end.
    final urgent = <OfflineMissingFile>[];
    // Decisions already crossed, in order, and the current one's two halves. A half is handed to [standing] when the
    // walk leaves its decision, which is what lets the cheap half go first without letting it outrank a newer decision.
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
      final wants = await _flags.page(after: cursor, limit: _pageSize);
      if (wants.isEmpty) {
        walkedAll = true;
        break;
      }
      cursor = wants.last.cursor;

      // Thumbhash and storability come from upstream, never the fork's copy, so an edited or trashed asset is handled
      // as it is now.
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
        // The row carries the live answer — `page` joins the camera roll rather than reading a column — so this is the
        // index's copy being corrected against it, not a stored value being refreshed.
        if (want.localCopy != _index.localCopyOf(want.id)) {
          localCopyMoved[want.id] = want.localCopy;
        }
        final isErrand = errands.contains(want.id);
        // Files the mirror deliberately does not fetch, because the camera roll already holds them. Counted, so the
        // progress line does not sit short for ever over photos that are on the phone twice over — but counted *apart*
        // from `unavailable`, which means "upstream will not give us this": nothing here failed. Derived from the
        // difference between what the row implies and what the live asset asks for, so it needs no column of its own
        // and cannot drift from [filesFor].
        final wantedFiles = filesFor(asset, want.quality, errand: isErrand);
        // Only the camera-roll skip counts here. An asset the server has not derived yet also yields no files, but those
        // are *coming*: counting them would report a photo uploaded a moment ago as one the store will never hold.
        final skipped = asset.thumbHash.isEmpty ? 0 : _index.wantedFilesOf(want.id) - wantedFiles.length;
        if (skipped > 0) {
          onDevice += skipped;
        }

        // What the errand is still waiting for: a file already here is done, and one the server has refused for good is
        // never coming, but one in flight still belongs to the errand — dropping the mark then would hand its retry back
        // to the queue as ordinary bulk work.
        var awaited = 0;
        for (final file in wantedFiles) {
          final held = _index.holds(want.id, file.variant, file.token);
          if (!held && !abandoned.contains(file.name)) {
            awaited++;
          }
          if (held || inFlight.contains(file.name) || abandoned.contains(file.name)) {
            continue;
          }
          // Capped at what could ever be handed over: while the walk is still chasing cheap files, one decision's
          // full-size half would otherwise grow to the size of the library before the first hand-over.
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
        // An errand is over when its files are here. Only concluded for a row this walk actually read, and acted on by
        // the caller, so a pass that stopped at its budget cannot forget an errand it never looked at.
        //
        // And never over an item that asks for *nothing*, which is not the same as one that asks for nothing more.
        // `filesFor` returns an empty list for an asset the server has not derived a thumbnail for yet, and a photo
        // uploaded from this phone is in that state for the first few seconds — which is precisely when someone taps
        // *Save offline* on it. Reading that as "already have it" retires the errand before a byte moves, and with the
        // errand goes the one thing that makes the mirror fetch a full-size copy of a photo the camera roll still
        // holds: the button then offers *Remove offline* for an item nothing was ever stored for.
        if (isErrand && awaited == 0 && wantedFiles.isNotEmpty) {
          satisfiedErrands.add(want.id);
        }
      }

      // Nothing further can fit: this decision's cheap half already fills what is left, and every decision behind it is
      // older. When no cheap file is missing anywhere, the full-size half settles it instead. The errand bucket is never
      // the reason to stop — it is the size of what was tapped, and it outranks whatever would be dropped anyway.
      if (base.length >= _missingBudget - standing.length ||
          (!chaseBase && fullSize.length >= _missingBudget - standing.length)) {
        break;
      }
    }
    takeDecision();

    // Errands first, and they keep their room whatever the walk found: the batch is a window, and being crowded out of
    // it is exactly how a hand-saved photo ends up waiting for a hundred thousand previews.
    into.addAll(urgent.take(_missingBudget));
    final room = _missingBudget - into.length;
    truncated |= standing.length > room;
    into.addAll(standing.take(room));

    // Two different questions: whether every row was read — which is what makes the counts above trustworthy — and
    // whether everything they implied fitted, which is what may let the next pass stay asleep.
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
    await _ready;
    return _exclusive(_reclaim);
  }

  /// [reclaim], on cold start, when there is a reason to. Two reasons beat the interval.
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

  Future<bool> _reclaim() async {
    _emit(_status.copyWith(isWorking: true, clearError: true));

    try {
      final upstreamWrites = _upstreamWrites;
      if (await _repository.assetCount() == 0) {
        _log.info('No assets known yet; refusing to reclaim');
        return false;
      }

      // Flipping the video form supersedes every stored video at once, which the share guard would otherwise refuse. It
      // is the one reduction here that was instructed rather than inferred, so it may say so.
      final form = offlineVideoForm();
      final recorded = await _flags.videoForm();
      final instructed = recorded != null && recorded != form;
      if (recorded == null) {
        // Baseline now rather than on the way out: a pass that stops early
        // would leave the next flip undetectable too.
        await _flags.setVideoForm(form);
      }

      // Every file this pass may keep. It does *not* consult the selection: deselecting never makes a file deletable,
      // only "free up space" does.
      final wantedHashes = <int>[];
      String? heldCursor;
      while (true) {
        final held = await _flags.heldPage(limit: _pageSize, afterName: heldCursor);
        if (held.isEmpty) {
          break;
        }
        heldCursor = held.last.name;

        final details = await _repository.detailsFor(held.map((row) => row.assetId).toSet().toList());
        for (final row in held) {
          if (details.containsKey(row.assetId)) {
            wantedHashes.add(offlineNameHash(row.name));
          }
        }
      }

      // Plus everything about to be fetched, so a file landing during the walk is not swept the moment it arrives.
      final forgotten = <String>[];
      OfflineWantCursor? cursor;
      while (true) {
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
          // `errand: true` on purpose — this list says what may not be swept, so it takes the widest set a decision
          // could ask for. Guessing narrower here deletes a file the next pass would immediately fetch again.
          for (final file in filesFor(asset, want.quality, errand: true)) {
            wantedHashes.add(offlineNameHash(file.name));
          }
        }

        // Absent from `detailsFor` is not enough: it filters to what can be stored, so a trashed or locked asset is
        // missing from it too, and the trash is undoable. Only an asset with no row at all is gone for good.
        final missing = [
          for (final want in wants)
            if (!details.containsKey(want.id)) want.id,
        ];
        if (missing.isNotEmpty) {
          final known = await _repository.existingIds(missing);
          forgotten.addAll(missing.where((id) => !known.contains(id)));
        }
      }

      // Everything queued but not yet written is wanted too, or the walk would
      // delete a file the downloader is about to replace.
      for (final entry in _queue.entries) {
        wantedHashes.add(offlineNameHash(entry.file.name));
      }

      // The wanted set was read across many queries, so a table that moved underneath it describes half of one library
      // and half of another. This gate takes no override — and it is stricter than the fingerprint it replaces, which
      // could not see an asset change in place at all. A count of writes and not the pass flag: see [_upstreamWrites].
      if (_upstreamWrites != upstreamWrites) {
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

      // Past the gate: a half-populated database looks exactly like a library
      // emptied on the server.
      if (forgotten.isNotEmpty) {
        _log.info('Forgetting ${forgotten.length} decision(s) about photos the server no longer has');
        await _flags.forget(forgotten);
      }

      // The isolate writes to this database through a second connection. Both sides wait on the lock rather than fail,
      // but downloads landing mid-walk have nothing to gain from contending for it.
      await _flushHeld();
      final root = await offlineStoreRoot();

      _reclaiming = true;
      final result = await offlineReclaimStore(
        databasePath: await offlineDatabasePath(),
        pinnedRoot: p.join(root, kOfflinePinnedDirectory),
        wantedHashes: Int64List.fromList(wantedHashes),
        expected: instructed,
      ).whenComplete(() => _reclaiming = false);
      await _flushHeld();

      if (result.unreadable > 0 || result.failed > 0) {
        _log.warning(
          'Integrity pass could not read ${result.unreadable} file(s) and could not delete ${result.failed}',
        );
      }
      if (result.removed > 0) {
        _log.info('Reclaimed ${result.removed} file(s) no longer wanted');
        // A stale entry in the native index costs a failed `open`; after a sweep it is worth one rebuild rather than
        // paying for all of them. And the last completed sync no longer holds, so the next must look again.
        await offlineForgetIndex();
        _upstreamMoved = true;
      }

      if (result.refused > 0) {
        _log.warning('Integrity pass refused to remove ${result.refused} file(s); the library is untouched');
        await _flags.setReclaimPending();
        _emit(
          _status.copyWith(
            // On screen, not just in the log: a refusal otherwise looks like a
            // pass that found nothing to do, or like the app ignoring a tap.
            lastError:
                'Kept ${result.refused} file(s) that appear unused. The photo list looked '
                'incomplete, so nothing was deleted. This resolves itself once syncing finishes.',
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

  /// The files an asset needs to be usable with no network: the thumbnail at every rung, the preview at every rung but
  /// the lowest, for a photo and a video alike, plus the big file at the rung that names it (FORK.md §3.2).
  List<OfflineFile> filesFor(OfflineAsset asset, OfflineQuality quality, {bool errand = false}) {
    if (!quality.isWanted) {
      return const [];
    }

    // Nothing is fetchable for an asset the server has not derived yet: no thumbhash means no thumbnail and no preview
    // exist, so every URL built here would 404 — and the cache buster is *in* the name, so those 404s would be recorded
    // against names nobody will ask for again. A photo uploaded from this phone is in this state for a few seconds, which
    // is exactly when a pass runs now. It arrives with the thumbhash, and that is a change the mirror hears about.
    if (asset.thumbHash.isEmpty) {
      return const [];
    }

    final files = [
      OfflineFile(getThumbnailUrlForRemoteId(asset.id, thumbhash: asset.thumbHash), OfflineVariant.thumbnail),
    ];

    // What the camera roll already holds, the mirror does not fetch *automatically*. Only the expensive half: the
    // thumbnail and preview are still mirrored at whatever rung the selection asked for, and they are the floor that
    // keeps the item openable the moment the local copy stops being usable — an edit, *Prefer remote images*, or the
    // file being deleted. A rung that selects nothing still fetches nothing; this removes files, it never adds any.
    //
    // An [errand] overrides it. "Save offline" is a request for *this app's own copy*, usually made precisely because
    // the camera roll one is about to go, so answering it with "you already have that" answers a question nobody asked
    // — and would leave the button offering *Remove offline* for a photo whose original was never stored.
    final localUsable = !errand && asset.localCopyUsable;

    // And an errand overrides the *rung* as well: it is about these items rather than a standing preference, so it
    // takes the top of the ladder even for a library kept at previews (FORK.md §3.6). It has to be applied here rather
    // than by writing a wider rung onto the row, because `quality` there is what the reclaim bands read to decide what
    // a selection maintains — inflating it makes a hand-saved copy indistinguishable from library and unreclaimable.
    final rung = errand ? kOfflineErrandQuality : quality;

    // Below the preview rung the thumbnail is all there is: enough for the timeline to draw off-grid, and the cheapest
    // way to keep a large library browsable. Nothing above it applies either, since every rung that asks for a full-size
    // file also asks for the preview.
    if (!rung.keepsPreview) {
      return files;
    }
    files.add(
      OfflineFile(
        getThumbnailUrlForRemoteId(asset.id, type: AssetMediaSize.preview, thumbhash: asset.thumbHash),
        OfflineVariant.preview,
      ),
    );

    if (asset.isImage) {
      if (rung.keepsOriginal && !localUsable) {
        files.add(
          OfflineFile(
            offlineOriginalUrl(asset.id, isEdited: asset.isEdited, thumbHash: asset.thumbHash),
            OfflineVariant.original,
          ),
        );
      }
      // A Live Photo's motion part, at the rung that asks for videos. It is a file of *this* item, not an item of its
      // own: the server keeps it as a hidden asset with no thumbnail of any kind, and the viewer asks for it under the
      // motion id (`video_viewer.widget.dart`), which is the URL it is stored under here.
      final motion = asset.motionVideoId;
      if (motion != null && rung.videoTier != OfflineVideoTier.none && !localUsable) {
        files.add(OfflineFile(offlineVideoUrl(motion), OfflineVariant.video));
      }
    } else {
      switch (rung.videoTier) {
        case OfflineVideoTier.none:
          break;
        // Switched on rather than tested for truth: a smaller flavour would be a
        // third case here and a different URL, and nothing else would move.
        case OfflineVideoTier.playback:
          if (!localUsable) {
            files.add(OfflineFile(offlineVideoUrl(asset.id), OfflineVariant.video));
          }
      }
    }
    return files;
  }

  // --------------------------------------------------------------------------- Progress

  /// A download reached a final state.
  /// Progress from a big file, kept for the log rather than for the screen: the status line counts files, and a
  /// per-file bar would be a second, disagreeing account of the same work.
  void onTaskProgress(TaskProgressUpdate update) {
    final previous = _progress[update.task.taskId];
    final now = DateTime.now();
    _progress[update.task.taskId] = (fraction: update.progress, at: now);
    _lastMovement = now;

    // Every quarter, so a slow file leaves a trail without a line per percent.
    if ((previous?.fraction ?? 0) ~/ 0.25 != update.progress ~/ 0.25 && update.progress > 0) {
      _log.fine('${(update.progress * 100).round()}% of ${_describe(update.task)}');
    }
  }

  /// A task left the plugin's holding queue. Recorded as its first sign of life, so a small file — which reports no
  /// progress — that hangs once running is told apart from one still waiting its turn.
  void onTaskStarted(TaskStatusUpdate update) {
    final now = DateTime.now();
    _progress[update.task.taskId] ??= (fraction: 0, at: now);
    _lastMovement = now;
  }

  void onTaskFinished(TaskStatusUpdate update) => unawaited(_onTaskFinished(update));

  Future<void> _onTaskFinished(TaskStatusUpdate update) async {
    _queue.noteFinished(fullSize: _isFullSizeTask(update.task));
    _lastMovement = DateTime.now();
    final reaped = _reaped.remove(update.task.taskId);

    final started = _outstandingSince.remove(update.task.taskId);
    // Timed for the big files only: a line per thumbnail would be most of the log.
    if (_progress.remove(update.task.taskId) != null && started != null && _isFullSizeTask(update.task)) {
      final seconds = DateTime.now().difference(started).inSeconds;
      _log.fine('${update.status.name} after ${seconds}s: ${_describe(update.task)}');
    }

    if (update.status == TaskStatus.complete) {
      final generation = _storeGeneration;
      final row = await _completedRow(update);
      if (row != null && generation == _storeGeneration) {
        _bufferHeld(row);
      }
      unawaited(_flags.clearFailure(update.task.taskId));
      _queue.noteSucceeded();
    } else if (update.status == TaskStatus.failed || update.status == TaskStatus.notFound) {
      final reason = update.exception?.description ?? update.status.name;
      _log.warning('Download ${update.status.name}: ${_describe(update.task)} — $reason');
      switch (classifyOfflineFailure(update)) {
        case OfflineFailureKind.file:
          // A 404 is the server's answer, not a hiccup — an asset whose thumbnail it has not generated has no thumbhash
          // either, so the URL says `c=` and stays wrong until it does. Recorded so the pass stops asking for it after a
          // few tries rather than every time, for good. Abandoning cannot outlive the cause, because the thumbhash is
          // *in* the name, so the file it names is a different file once the server produces one.
          await _flags.recordFailure(update.task.taskId);
          _emitSoon(_status.copyWith(failed: await _flags.abandonedCount()));
        case OfflineFailureKind.transient:
          // Nothing about this file: the network, the session or the server's front door. Not counted — that is how
          // an afternoon off-grid used to give up on the selection — but every file behind it would fail the same way,
          // so the queue holds off instead, and the file is found missing and asked for again once it resumes.
          _queue.backOff();
      }
    } else if (update.status == TaskStatus.canceled) {
      // The mirror's own doing — a pass handing back what it had queued past the window, a stuck task given up on, or a
      // pause. Not a failure, and there can be hundreds at once, so it is not worth a line each.
      _log.fine('Handed back: ${_describe(update.task)}');
    } else {
      _log.warning('Download ended as ${update.status.name}: ${_describe(update.task)}');
    }
    _emitSoon(_queueCountsOn(_status));

    unawaited(_queue.topUp());

    // The queue drained but the last pass stopped at its budget, so there is
    // more to look for. Not on most cancellations: a pass handing back what it queued past the window re-plans those
    // files itself, and a stop is undone by a pass. A stop clears the queue and leaves [_upstreamMoved] set, so every
    // cancelled task would otherwise start a pass of its own and hand fresh work back to the downloader — on sign-out,
    // under the token about to be revoked. A stuck task given up on is the exception: nothing has planned its file, and
    // when it was the last thing outstanding, nothing else is coming to.
    if ((update.status != TaskStatus.canceled || reaped) && _queue.isIdle && _upstreamMoved && !_isPaused) {
      unawaited(sync());
    }
  }

  /// What the downloader has been holding for too long, by name.
  ///
  /// A task that never reaches a final state — waiting for Wi-Fi, waiting to retry, dropped while the app was killed —
  /// calls nothing back, so it sits in the count with no other trace. Age is what separates that from a video that is
  /// simply large: two passes seconds apart always see the same running download, and saying so every time is noise.
  ///
  /// Answers whether it handed anything back, which the caller needs: a cancelled task's file was skipped by this
  /// walk as in flight, so nothing has planned it and the pass may not call itself settled.
  Future<bool> _reportOutstanding(List<Task> outstanding) async {
    if (!_loadedOutstandingSince) {
      // Merged, not replaced: this pass may already have handed tasks over, and those are genuinely new.
      _outstandingSince = {...await _flags.outstandingSince(), ..._outstandingSince};
      _loadedOutstandingSince = true;
    }

    final now = DateTime.now();
    final since = {for (final task in outstanding) task.taskId: _outstandingSince[task.taskId] ?? now};
    _outstandingSince = since;
    _watchingSince.removeWhere((id, _) => !since.containsKey(id));
    for (final id in since.keys) {
      _watchingSince[id] ??= now;
    }
    // Written every pass, so a task handed over in one session is still known to be old in the next. The map is the
    // size of the hand-over window (`offline_queue.dart`), so this is at most a couple of hundred entries.
    unawaited(_flags.setOutstandingSince(since));

    final stuck = outstanding.where((task) => now.difference(since[task.taskId]!) >= _stuckAfter).toList();
    if (stuck.isEmpty) {
      return false;
    }
    // A warning only while the group is silent: with a deep window, tasks waiting their turn behind slow running ones
    // are old as a matter of course.
    _log.log(
      offlineGroupSilent(now: now, groupMoved: _lastMovement) ? Level.WARNING : Level.FINE,
      '${stuck.length} download(s) outstanding for over ${_stuckAfter.inMinutes} minutes '
      '(Wi-Fi only: ${_settings.appConfig.offlineWifiOnly}): '
      '${stuck.take(10).map((task) => '${_describe(task)} ${_progressOf(task, now)}').join(', ')}'
      '${stuck.length > 10 ? ', …' : ''}',
    );

    // Cancelled rather than waited on any longer. A task the downloader holds but does not move — dropped when the app
    // was replaced, deferred by the system, or left behind something that never ended — reports nothing and ends
    // nothing, so it keeps one of the group's slots for good. Cancelling ends it, which frees the slot, and the
    // next pass finds the file missing and asks again.
    final dead = [
      for (final task in stuck)
        if (offlineTaskIsDead(
          now: now,
          lastSign: _progress[task.taskId]?.at,
          groupMoved: _lastMovement,
          watchingSince: _watchingSince[task.taskId] ?? now,
        ))
          task.taskId,
    ];
    if (dead.isEmpty) {
      return false;
    }
    _log.warning('Cancelling ${dead.length} download(s) that have not moved; they will be fetched again');
    for (final id in dead) {
      _outstandingSince.remove(id);
      _watchingSince.remove(id);
      _progress.remove(id);
      _reaped.add(id);
    }
    unawaited(_flags.setOutstandingSince(_outstandingSince));
    unawaited(_downloads.cancel(dead));
    return true;
  }

  /// What one outstanding task has to show for its time: how far it has got, and how long since it last said so.
  /// "nothing reported" is the telling one — the plugin is holding it, but it is not moving bytes.
  String _progressOf(Task task, DateTime now) {
    final progress = _progress[task.taskId];
    if (progress == null) {
      return '(nothing reported)';
    }
    return '(${(progress.fraction * 100).round()}%, last ${now.difference(progress.at).inSeconds}s ago)';
  }

  /// A task in the terms the rest of the log uses: which item, which file, and where it was coming from.
  String _describe(Task task) =>
      '${task.metaData.split('|').first} ${_variantOf(task)?.name ?? '?'} <${task.url}>';

  /// The variant a task fetches, read from the metadata it was handed over with, or null when that does not name one.
  /// Checked rather than indexed: a task in the plugin's persistent queue can come from another build, and a throw here
  /// would end the completion callback before it records, backs off or tops the queue up.
  static OfflineVariant? _variantOf(Task task) {
    final parts = task.metaData.split('|');
    final variant = parts.length == 3 ? int.tryParse(parts[1]) : null;
    return variant != null && variant >= 0 && variant < OfflineVariant.values.length
        ? OfflineVariant.values[variant]
        : null;
  }

  /// Whether a task fetches an original or a video. The queue holds fewer of those at once than of anything else
  /// (`offline_queue.dart`).
  static bool _isFullSizeTask(Task task) => _variantOf(task)?.isFullSize ?? false;

  Future<OfflineHeldRow?> _completedRow(TaskStatusUpdate update) async {
    final parts = update.task.metaData.split('|');
    if (parts.length != 3) {
      // Nothing can be written down about it, so it stays missing and is fetched again on the next pass, for good.
      _log.severe('Downloaded file has no usable metadata: ${update.task.taskId}');
      return null;
    }
    final variant = _variantOf(update.task);
    if (variant == null) {
      _log.severe('Downloaded file names no known variant: ${update.task.taskId}');
      return null;
    }
    try {
      return OfflineHeldRow(
        name: update.task.taskId,
        assetId: parts[0],
        variant: variant,
        token: int.parse(parts[2]),
        size: await File(await update.task.filePath()).length(),
      );
    } catch (error) {
      _log.warning('Could not measure ${update.task.taskId}', error);
      return null;
    }
  }

  /// Counts move here rather than being re-derived: a directory walk per completed file would be six figures of stats
  /// every few seconds, and the integrity pass corrects any drift.
  void _bufferHeld(OfflineHeldRow row) {
    _index.markHeld(row.assetId, row.variant, row.token, row.size);
    _heldBuffer.add(row);
    _scheduleRevisionBump();
    _emitSoon(_countsOn(_status));

    // Not while a failed write is waiting out its back-off: it would fail again, once per completed file.
    if (_heldBuffer.length >= 100 && _heldRetry == null) {
      unawaited(_flushHeld());
      return;
    }
    _heldTimer ??= Timer(const Duration(seconds: 2), () => unawaited(_flushHeld()));
  }

  /// [force] writes even while the integrity pass holds the database, which is worth a wait on its lock only when there
  /// will be no later chance.
  Future<void> _flushHeld({bool force = false}) async {
    _heldTimer?.cancel();
    _heldTimer = null;
    if (_heldBuffer.isEmpty && _readBuffer.isEmpty) {
      return;
    }

    if (_reclaiming && !force) {
      // Deferred, not dropped: the pass can exit by exception and never reach
      // its own flush, and a file on disk with no row is fetched again.
      _heldTimer = Timer(const Duration(seconds: 2), () => unawaited(_flushHeld()));
      return;
    }

    final generation = _storeGeneration;
    final batch = List<OfflineHeldRow>.from(_heldBuffer);
    _heldBuffer.clear();
    final reads = _readBuffer.toList();
    _readBuffer.clear();
    List<String> superseded;
    try {
      superseded = await _flags.markHeld(batch);
    } catch (error, stack) {
      // Put back, not dropped: these files are on disk and the index already counts them, so losing the rows would
      // leave them unrecorded until the integrity pass and fetched again meanwhile. Callers do not await this, so
      // nothing above would catch the error either.
      if (generation != _storeGeneration) {
        return;
      }
      final retry = _heldRetry == null
          ? _heldRetryFirst
          : (_heldRetry! * 2 > _heldRetryLimit ? _heldRetryLimit : _heldRetry! * 2);
      _heldRetry = retry;
      _log.warning(
        'Could not record ${batch.length} downloaded file(s); will retry in ${retry.inSeconds}s',
        error,
        stack,
      );
      _heldBuffer.insertAll(0, batch);
      // Replaces any shorter timer a completion armed meanwhile, so the back-off holds.
      _heldTimer?.cancel();
      _heldTimer = Timer(retry, () => unawaited(_flushHeld()));
      return;
    }
    _heldRetry = null;
    // Recorded before a wipe began, and deleteAll removes the rows; telling the native side about the files now would
    // list ones that are gone.
    if (generation != _storeGeneration) {
      return;
    }
    if (reads.isNotEmpty) {
      try {
        await _flags.touchHeld(reads, DateTime.now());
      } catch (error) {
        // Only the eviction order suffers, and only for these files.
        _log.fine('Could not record ${reads.length} use(s) of stored files', error);
      }
    }
    if (superseded.isNotEmpty) {
      // An older generation of a file that has just arrived — an edit moved its name. Its row is gone, so nothing would
      // count or evict it until the integrity pass.
      try {
        final root = await offlineStoreRoot();
        final deleted = await offlineDeletePaths([for (final name in superseded) offlinePinnedPath(root, name)]);
        if (deleted.failed > 0) {
          _log.warning('${deleted.failed} superseded file(s) could not be deleted; the integrity pass will retry them');
        }
        await offlineNoteRemoved(superseded);
      } catch (error, stack) {
        _log.warning('Could not remove ${superseded.length} superseded file(s)', error, stack);
      }
    }
    if (batch.isEmpty) {
      return;
    }
    try {
      await offlineNoteStored([for (final row in batch) row.name]);
    } catch (error, stack) {
      _log.warning('Could not tell the store about ${batch.length} downloaded file(s)', error, stack);
    }
    // The store has grown, so it may now be over its ceiling.
    _evictSoon();
  }

  // --------------------------------------------------------------------------- Browsing, and eviction

  /// What the native image path stored and served since it last said (FORK.md §3.4).
  void _onStoreActivity(OfflineStoreActivity activity) {
    for (final name in activity.read) {
      _noteRead(name);
    }
    if (activity.stored.isNotEmpty) {
      unawaited(
        _recordStored(activity.stored).catchError((Object error, StackTrace stack) {
          // Unrecorded files are claimed by the queue if a selection wants them, and swept by the integrity pass if not.
          _log.warning('Could not record ${activity.stored.length} file(s) kept while browsing', error, stack);
        }),
      );
    }
  }

  /// A stored file was shown, which makes it the last thing eviction takes.
  void _noteRead(String name) {
    _readBuffer.add(name);
    if (_heldRetry == null) {
      _heldTimer ??= Timer(const Duration(seconds: 2), () => unawaited(_flushHeld()));
    }
  }

  /// Writes down what browsing kept, as spares — or as the library's own files, when a selection happens to want them.
  ///
  /// A name is filed under the variant it is only if it is exactly the name the mirror would give that variant of
  /// that asset *now*: the thumbnail, the preview or the original `filesFor` would ask for. `held` keeps one row per
  /// asset and variant, so filing anything else there — a full-size rendition, a preview under a thumbhash an edit
  /// has since replaced — would push out the row for the file the mirror actually wants, and the queue would fetch it
  /// again. Those are kept under a key of their own instead, which makes them spares of no asset: counted, evictable,
  /// and swept by the integrity pass.
  ///
  /// An asset the mirror may not store at all — a locked-folder one, whose bytes must not sit outside the PIN gate —
  /// has its file deleted on the spot. Any other asset [detailsFor] leaves out — trashed, or uploaded moments ago and not
  /// synced here yet — keeps its file as a spare: deleting it would only mean fetching it again on the next visit.
  Future<void> _recordStored(List<(String, int)> stored) async {
    await _ready;
    final generation = _storeGeneration;

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
      // Every file an asset can have, at the widest rung: what the mirror would name each variant.
      final known = {for (final file in filesFor(asset, kOfflineErrandQuality, errand: true)) file.name: file};
      for (final (name, size) in files) {
        final file = known[name];
        rows.add(
          file == null
              ? _looseRow(name, size)
              : OfflineHeldRow(name: name, assetId: assetId, variant: file.variant, token: file.token, size: size),
        );
      }
    }

    if (generation != _storeGeneration) {
      // The store was wiped while this was being worked out, and these files with it.
      return;
    }
    for (final row in rows) {
      _bufferHeld(row);
    }
    if (refused.isNotEmpty) {
      final root = await offlineStoreRoot();
      await offlineDeletePaths([for (final name in refused) offlinePinnedPath(root, name)]);
      await offlineNoteRemoved(refused);
      _log.fine('Dropped ${refused.length} file(s) of items the mirror may not keep');
    }
  }

  /// A file kept while browsing that is not one of the variants the mirror tracks. Keyed by its own name, so it can
  /// never stand in for another file's row, and so it belongs to no asset — which makes it a spare. Filed under the kind
  /// it looks like, so the storage figures put it in the right row.
  OfflineHeldRow _looseRow(String name, int size) =>
      OfflineHeldRow(name: name, assetId: name, variant: offlineVariantOfName(name), token: 0, size: size);

  /// Asks for [_evict] once the current pass is done. Coalesced: every write asks, and one eviction answers them all.
  void _evictSoon() {
    if (_evictionPending) {
      return;
    }
    _evictionPending = true;
    unawaited(() async {
      try {
        await _ready;
        await _exclusive(_evict);
      } catch (error, stack) {
        _log.warning('Eviction failed', error, stack);
      } finally {
        _evictionPending = false;
      }
    }());
  }

  /// Evicts spares, least recently used first, until the store is back under its ceiling (FORK.md §3.4.1). The caller
  /// holds the pass lock.
  ///
  /// Only spares, and never an item whose *Save offline* is still on its way (`evictionCandidates`). If that is not
  /// enough, what is left is the library: downloading stops, and the screen says the store is full.
  Future<void> _evict() async {
    await _measureDevice();
    final ceiling = _ceiling;
    if (ceiling == null || _isUnderLimit()) {
      // Asked after every batch of files, so it only speaks when the answer changed.
      if (_status.isOverLimit) {
        _emit(_status.copyWith(isOverLimit: false));
      }
      return;
    }
    await _flushHeld();

    final int target = ceiling - math.min(ceiling ~/ 20, _evictionSlack);
    final root = await offlineStoreRoot();
    final removed = <String>[];
    var freed = 0;

    // Normally one round: the query hands back whole items, oldest first, until what is over the target is covered. A
    // second only when the index and the rows disagree about sizes, and every round removes rows, so it ends.
    while (_index.heldBytes > target) {
      final batch = await _flags.evictionCandidates(bytes: _index.heldBytes - target);
      if (batch.isEmpty) {
        break;
      }

      final deleted = await offlineDeletePaths([for (final row in batch) offlinePinnedPath(root, row.name)]);
      if (deleted.failed > 0) {
        _log.warning('${deleted.failed} evicted file(s) could not be deleted; the integrity pass will retry them');
      }
      for (final row in batch) {
        _index.dropHeld(row.assetId, row.variant, row.size);
        freed += row.size;
      }
      await _flags.dropHeld(batch.map((row) => row.name));
      removed.addAll(batch.map((row) => row.name));
    }

    if (removed.isNotEmpty) {
      // A hand-saved item whose files have all gone stops being wanted, or the next pass would fetch it straight back.
      await _flags.dropFetchedWithoutFiles();
      await offlineNoteRemoved(removed);
      await _loadIndex();
      _log.info('Evicted ${removed.length} spare file(s), ${(freed / (1024 * 1024)).toStringAsFixed(1)} MB');
    }
    final full = !_isUnderLimit();
    if (removed.isNotEmpty || full != _status.isOverLimit) {
      _emit(
        _countsOn(_status).copyWith(
          isOverLimit: full,
          // Tiles of evicted items draw differently now.
          revision: removed.isEmpty ? null : _status.revision + 1,
        ),
      );
    }
    if (!full && !_isPaused) {
      unawaited(_queue.topUp());
    }
  }

  // --------------------------------------------------------------------------- Controls

  /// Stops or resumes downloading, without changing what is wanted. Persisted: a stop that forgets itself on the next
  /// launch is not a stop.
  Future<void> setPaused(bool value) async {
    await _exclusive(() => _setPaused(value));
    if (!value) {
      await sync();
    }
  }

  Future<void> _setPaused(bool value) async {
    await _settings.write(SettingsKey.offlinePaused, value);
    _emit(_status.copyWith(isPaused: value));

    if (!value) {
      return;
    }
    await _stopDownloads();
  }

  /// Hands back everything queued, without recording a pause.
  ///
  /// The distinction from [setPaused] is the whole point. *Paused* is a state the offline screen presents as the
  /// user's own decision and it survives restarts; stopping because a token is about to be revoked, or because the
  /// constraint the queued tasks carry has just changed, is neither. Persisting one of those leaves downloading
  /// silently off with nothing on any screen able to explain it — and, after a sign-out, greets the next sign-in that
  /// way.
  Future<void> stopDownloads() => _exclusive(_stopDownloads);

  Future<void> _stopDownloads() async {
    _upstreamMoved = true;
    // A stop is not to be undone by the cancellations of tasks given up on just before it.
    _reaped.clear();
    await _downloads.cancelAll();
    _queue.clear();
    _emit(_status.copyWith(queued: 0, pending: 0));
  }

  /// Forgets which files gave up, so the next pass tries them again.
  Future<void> retryFailed() async {
    await _flags.forgetFailures();
    _upstreamMoved = true;
    _emit(_status.copyWith(failed: 0));
    await sync();
  }

  /// Removes every stored file.
  ///
  /// [forgetSelection] makes it an abandonment rather than an emptying: what the user chose to keep goes with the
  /// bytes, and so does every decision derived from it. Nothing else can do that job — the selection is a settings
  /// value and the decisions are this fork's own database, so neither is touched by signing out
  /// (`AuthService.clearLocalData` resets upstream's synced tables and nothing more). Without it, erasing the
  /// downloads deletes the files and leaves the instruction to fetch them, and the next sign-in re-derives the whole
  /// selection and starts again.
  Future<void> deleteAll({bool forgetSelection = false}) async {
    await _ready;
    await _exclusive(() async {
      // First, so a download finishing while this runs is not recorded into the store being wiped.
      _storeGeneration++;
      // Only where the selection stands does downloading have to be stopped *and remembered*: what is left selected
      // would otherwise be fetched straight back. With the selection gone there is nothing to fetch, and a pause
      // nobody asked for is one more thing to discover later with no explanation.
      if (forgetSelection) {
        await _stopDownloads();
      } else {
        await _setPaused(true);
      }
      _heldBuffer.clear();
      _heldTimer?.cancel();

      await offlineDeleteStore(await offlineStoreRoot());
      // Again, now the files are gone. A completion delivered during the wipe read the generation after the first bump,
      // and may have buffered its row since; deleting a large store takes seconds, so that is not a narrow window.
      _storeGeneration++;
      _heldBuffer.clear();
      _readBuffer.clear();
      _heldTimer?.cancel();
      _heldTimer = null;
      _heldRetry = null;
      if (forgetSelection) {
        // Through the same lock every other write to it takes, so a tap landing on the settings screen at this instant
        // cannot merge a change into a selection that is being abandoned.
        await _settings.write(SettingsKey.offlinePolicy, OfflinePolicy.empty.encode());
        await _flags.clearAll();
        _index.clear();
      } else {
        await _flags.clearHeld();
        _index.clearHeld();
      }
      await offlineForgetIndex();

      _emit(
        _countsOn(_status).copyWith(
          failed: 0,
          // Both describe what a selection asked for and could not get, so with the selection gone they say nothing
          // until a new one produces them. Emptying the store alone leaves them true.
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
    // Last chance to write: deferring here would hand the work to a pass that
    // may outlive this object, through a timer holding it alive.
    await _flushHeld(force: true);
    _heldTimer?.cancel();
    await _statusController.close();
  }
}
