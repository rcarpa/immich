/// immich-sync fork — keeps the blob store equal to what the user selected (FORK.md §3.3). Three passes of increasing
/// cost, because the frequent case must be nearly free: [check] is a few aggregates and runs on every resume, [sync]
/// pages the wanted list and queues what is missing, and [reclaim] walks the whole store on its own isolate, weekly or
/// on demand.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
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

/// How many of the newest assets a policy pass re-examines whatever its watermark says.
///
/// A constant, not a fraction of the library: it exists to catch rows the sync delivered out of `updatedAt` order, and
/// those are always among the most recently changed. Wide enough to cover a burst of uploads and the jobs the server
/// runs over them.
const _recentWindow = 500;

/// How often that re-examination is worth paying for.
///
/// Not every pass, because it cannot be made cheap: upstream indexes `remote_asset_entity` on checksum, stack, uploaded
/// date and `(owner, visibility, deleted, created)` — **not** on `updated_at` — so ordering by it scans and sorts the
/// whole table. `assetsChangedSince` gets away with the same ordering because its `WHERE` leaves almost nothing to sort;
/// a window with no `WHERE` does not. Running it on every wake-up put a library-proportional sort in front of the lock
/// that `applyPolicy` needs, which made toggling a setting wait behind a queue of them.
///
/// A minute is as good as instant here: this repairs a fault that persists until something notices, and the walk that
/// should have caught it already ran.
const _recentScanEvery = Duration(minutes: 1);

/// How long a task may sit with the downloader before it is worth a line in the log. Long enough that a large video on
/// a slow link is not news, short enough to notice a task that will never finish.
const _stuckAfter = Duration(minutes: 15);

/// How long the store may go unverified. The pass costs a walk over every file and only catches what the incremental
/// paths cannot, so it is rare.
const _reclaimInterval = Duration(days: 7);

class OfflineSyncService {
  OfflineSyncService(this._repository, this._flags, this._downloads, this._settings) {
    _status = _status.copyWith(isPaused: _settings.appConfig.offlinePaused);
    _index.publish();
    _downloads.onFinished = onTaskFinished;
    _downloads.onProgress = onTaskProgress;
    // The native side holds no setting of its own, so tell it ours before
    // anything can be browsed into the region it trims.
    unawaited(offlineSetCacheBudget(_settings.appConfig.offlineCacheBudget));
    _queue = OfflineDownloadQueue(
      _downloads,
      _settings,
      onHeld: _bufferHeld,
      onChanged: () => _emitSoon(_status.copyWith(queued: _queue.queued)),
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

  final _index = OfflineIndex();

  /// What to fetch next, and how much at once (`offline_queue.dart`).
  late final OfflineDownloadQueue _queue;
  late final Future<void> _ready;

  final _statusController = StreamController<OfflineStatus>.broadcast();
  OfflineStatus _status = const OfflineStatus();

  /// Passes run one at a time, through upstream's own mutex. A flag instead would let a decision from the UI interleave
  /// with `reclaim`, and let `setPaused(false)` do nothing because something else was running.
  final _passes = AsyncMutex();

  /// Reading the policy, merging a change into it and writing it back, as one step. Separate from [_passes] so a tap
  /// never queues behind a pass paging the whole library.
  final _policyWrites = AsyncMutex();

  /// Upstream, the fork's decisions and the viewer setting that names video files, as of the last completed pass.
  OfflineSignature? _signature;
  int? _flagRevision;
  String? _syncedVideoForm;

  /// Completed files waiting to be written down. Batched: a mirror in progress finishes several a second, each
  /// otherwise a transaction and a channel hop.
  final _heldBuffer = <OfflineHeldRow>[];
  Timer? _heldTimer;
  bool _reclaiming = false;

  Timer? _emitTimer;
  Timer? _revisionTimer;
  Timer? _checkTimer;

  /// When each outstanding task was first seen, so a pass can tell a long download from a stuck one.
  Map<String, DateTime> _outstandingSince = const {};

  /// How far the big files have got, and when they last said so. Only full-size copies report progress, so this holds
  /// a handful of entries: it is what separates a slow download from one that has stopped moving.
  final _progress = <String, ({double fraction, DateTime at})>{};

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

  /// The three figures a tile's bar is drawn from: what a setting maintains, what the mirror is fetching, and what is
  /// here (FORK.md §3.6).
  OfflineBar barOf(String assetId) => _index.barOf(assetId);

  bool get _isPaused => _settings.appConfig.offlinePaused;

  /// What browsing is holding, as of the last pass.
  int _browsingBytes = 0;

  /// Whether the persistent library may still grow.
  bool _isUnderLimit() {
    final limit = _settings.appConfig.offlineStorageLimit;
    return limit <= 0 || _index.heldBytes < limit;
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
      final (files, bytes) = await _flags.heldTotals();
      _index.load(rows, heldFiles: files, heldBytes: bytes);
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

  // --------------------------------------------------------------------------- Policy — what happens to photos that
  // arrive later ---------------------------------------------------------------------------

  OfflinePolicy get policy => OfflinePolicy.decode(_settings.appConfig.offlinePolicy);

  /// Bumped by every write, so a pass can tell it has been superseded and let the later one carry its work.
  int _policyGeneration = 0;

  /// Albums whose selection has moved and has not been re-derived yet; the flag says something needs the whole library.
  final _unappliedAlbums = <String>{};
  bool _unappliedLibrary = false;

  /// When the newest change waiting here was made — the stamp its rows will take, so a change that had to wait for a
  /// retry still outranks what came before it in the queue rather than being dated by the retry.
  DateTime? _unappliedAt;

  Future<void> _writePolicy(OfflinePolicy value) async {
    _policyGeneration++;
    await _settings.write(SettingsKey.offlinePolicy, value.encode());
    _signature = null;
  }

  /// The albums whose setting differs between two selections.
  static Set<String> _changedAlbums(OfflinePolicy from, OfflinePolicy to) => {
    ...from.albums.keys,
    ...to.albums.keys,
    ...from.excluded,
    ...to.excluded,
  }..removeWhere(
    (id) => from.albums[id] == to.albums[id] && from.excluded.contains(id) == to.excluded.contains(id),
  );

  /// Notes work to be done.
  void _recordUnapplied(Set<String>? scope, DateTime at) {
    if (_unappliedAt == null || at.isAfter(_unappliedAt!)) {
      _unappliedAt = at;
    }
    if (scope == null) {
      _unappliedLibrary = true;
      return;
    }
    _unappliedAlbums.addAll(scope);
  }

  /// Claims everything recorded so far, so exactly one pass owns it.
  ({Set<String>? albums, DateTime at}) _takeUnapplied(DateTime fallback) {
    final albums = Set<String>.from(_unappliedAlbums);
    final library = _unappliedLibrary;
    final at = _unappliedAt ?? fallback;
    _unappliedAlbums.clear();
    _unappliedLibrary = false;
    _unappliedAt = null;
    return (albums: library ? null : albums, at: at);
  }

  /// Decides for items that appeared since this last ran. Only assets with no decision recorded are touched, so a
  /// choice made by hand is never overwritten by a rule.
  Future<int> _applyPolicy() async {
    final policy = this.policy;
    // The instruction reaches these items now, so that is when they were asked for: a photo that arrives during a
    // library-wide sync is fetched ahead of the backlog rather than behind it.
    final touchedAt = DateTime.now();
    var decided = 0;
    var watermark = await _flags.policyWatermark();

    while (true) {
      final candidates = await _repository.assetsChangedSince(watermark?.$1, watermark?.$2, limit: _pageSize);
      if (candidates.isEmpty) {
        break;
      }

      decided += await _decide(candidates, policy, touchedAt);

      watermark = (candidates.last.updatedAt, candidates.last.id);
      await _flags.setPolicyWatermark(watermark);
    }

    // The watermark alone is not enough, and cannot be made enough: it walks `updatedAt`, which is the server's clock,
    // while upstream syncs by a cursor of its own. A row that arrives with an `updatedAt` below the mark is past the
    // walk above for ever, and the symptom is the worst kind — a photo taken and uploaded a moment ago that the mirror
    // simply never keeps, with no bar on its tile, no line in the log, and nothing but toggling the whole library off
    // and on to shake it loose.
    //
    // So the newest slice by `updatedAt` is re-examined regardless — but on a timer, not on every pass. The rows come
    // back through `undecided`, so nothing is written in the steady state, and the *reading* is what costs: `updatedAt`
    // is unindexed upstream (see [_recentScanEvery]).
    decided += await _scanRecent(policy, touchedAt);

    if (decided > 0) {
      _log.info('Policy decided to keep $decided new photo(s)');
      // With the revision, not just the counts: a decision is the moment a tile starts having something to say — an
      // empty track, for a photo now on its way — and the badge redraws on the revision alone. Without it the mark stays
      // blank until the first file lands and bumps it, which reads as the app noticing nothing at all until it is
      // suddenly finished.
      _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
    }
    return decided;
  }

  /// When the out-of-order backstop last ran.
  DateTime? _lastRecentScan;

  /// Re-examines the newest assets whatever the watermark says, at most once every [_recentScanEvery].
  ///
  /// The watermark walks `updatedAt` while upstream syncs by a cursor of its own, so a row arriving below the mark is
  /// past that walk for ever and the mirror simply never keeps the photo. This is the only thing that finds it.
  Future<int> _scanRecent(OfflinePolicy policy, DateTime touchedAt) async {
    final now = DateTime.now();
    final last = _lastRecentScan;
    if (last != null && now.difference(last) < _recentScanEvery) {
      return 0;
    }
    _lastRecentScan = now;

    final missed = await _decide(await _repository.recentlyChanged(limit: _recentWindow), policy, touchedAt);
    if (missed > 0) {
      // Worth a line: the watermark was supposed to have caught these, so this firing at all says the sync delivered
      // out of order.
      _log.info('Policy caught $missed photo(s) the watermark had passed over');
    }
    return missed;
  }

  /// Records a decision for whichever of [candidates] has none yet, and returns how many of them are wanted.
  ///
  /// Only assets with no decision recorded are touched, so a choice made by hand is never overwritten by a rule, and
  /// calling this twice over the same ids is free.
  Future<int> _decide(List<OfflineCandidate> candidates, OfflinePolicy policy, DateTime touchedAt) async {
    if (candidates.isEmpty) {
      return 0;
    }

    final fresh = await _flags.undecided(candidates.map((candidate) => candidate.id));
    final rows = [
      for (final candidate in candidates)
        // A rule that selects nothing is still a decision; no rule at all records nothing and leaves the item to be
        // picked by hand. Either way the watermark moves past it, so policy sees it once.
        if (policy.resolve(candidate.albumIds) case final quality? when fresh.contains(candidate.id))
          OfflineFlagRow(
            id: candidate.id,
            quality: quality,
            isImage: candidate.isImage,
            hasMotion: candidate.motionVideoId != null,
            createdAt: candidate.createdAt,
            touchedAt: touchedAt,
          ),
    ];
    if (rows.isEmpty) {
      return 0;
    }

    await _flags.set(rows);
    var decided = 0;
    for (final row in rows) {
      _index.setWanted(row.id, row.quality, isImage: row.isImage, hasMotion: row.hasMotion);
      if (row.quality.isWanted) {
        decided++;
      }
    }
    return decided;
  }

  /// Decides again for the albums the selection names, when what is in one of them has changed.
  Future<void> _applyAlbumChanges() async {
    final policy = this.policy;
    final named = {...policy.albums.keys, ...policy.excluded};
    final remembered = await _flags.albumSizes();

    if (named.isEmpty) {
      if (remembered.isNotEmpty) {
        await _flags.setAlbumSizes(const {});
      }
      return;
    }

    // An album the selection names that upstream no longer has at all. Asked of the album table rather than inferred
    // from the counts below, which come from the link table and so cannot tell a deleted album from an empty one.
    final alive = await _repository.existingAlbumIds(named);
    final vanished = {for (final id in named) if (!alive.contains(id)) id};
    if (vanished.isNotEmpty) {
      await _forgetAlbums(vanished);
      return;
    }

    final counts = await _repository.albumAssetCounts();
    final sizes = {for (final id in named) id: counts[id] ?? 0};
    final changed = {for (final entry in sizes.entries) if (remembered[entry.key] != entry.value) entry.key};

    if (changed.isEmpty) {
      // Albums the selection stopped naming: their own change already re-derived
      // what it had to, so this is only the record catching up.
      if (remembered.length != sizes.length) {
        await _flags.setAlbumSizes(sizes);
      }
      return;
    }

    // An album that lost items is the one case a derivation cannot answer, since it walks what is in the album now and
    // what left is by definition not there.
    final shrank = changed.any((id) => (sizes[id] ?? 0) < (remembered[id] ?? 0));
    final at = DateTime.now();

    if (!await _deriveOrDefer(policy, changed, at)) {
      return;
    }
    if (shrank) {
      await _reviewDecisions(policy, at);
    }
    await _flags.setAlbumSizes(sizes);
    _log.info('Re-derived ${changed.length} album(s) whose contents changed');
  }

  /// Drops albums upstream no longer has from the selection, and re-derives the whole library once.
  ///
  /// The selection names albums by id, so a deleted one would otherwise sit in it for ever — invisible, since the screen
  /// lists albums upstream has, and load-bearing, since an *excluded* album goes on suppressing its photos.
  ///
  /// The walk is **unscoped on purpose**, and this is the part that is easy to get wrong: the assets a vanished album
  /// affected can no longer be enumerated from it, because its rows in the link table died with it. Nor can
  /// [_reviewDecisions] find them — that walks decisions, and an excluded photo has none. Only a pass over the library
  /// can see that those photos now resolve to the library's own rung. A scoped derive here looks correct and does
  /// nothing at all, leaving a deleted *excluded* album with no effect until the library setting is toggled by hand.
  Future<void> _forgetAlbums(Set<String> ids) async {
    final at = DateTime.now();
    final next = ids.fold(policy, (current, id) => current.withAlbum(id, OfflineAlbumState.notIncluded));

    await _policyWrites.run(() async {
      await _writePolicy(next);
      _recordUnapplied(null, at);
    });

    final claimed = _takeUnapplied(at);
    if (!await _deriveOrDefer(next, claimed.albums, claimed.at)) {
      return;
    }
    // Whatever the pruned selection still names, recorded fresh: the vanished ids are gone from it, so nothing looks for
    // them again.
    final counts = await _repository.albumAssetCounts();
    final remaining = {...next.albums.keys, ...next.excluded};
    await _flags.setAlbumSizes({for (final id in remaining) id: counts[id] ?? 0});
    _log.info('Forgot ${ids.length} album(s) upstream no longer has, and re-derived the library');
    _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
  }

  /// A derivation in reverse: every decision the selection made, checked against what the selection says now.
  Future<void> _reviewDecisions(OfflinePolicy policy, DateTime at) async {
    String? cursor;

    while (true) {
      final decided = await _flags.derivedPage(afterId: cursor, limit: _pageSize);
      if (decided.isEmpty) {
        break;
      }
      cursor = decided.last.id;

      final ids = [for (final row in decided) row.id];
      final albums = await _repository.albumsOf(ids);
      // Whether upstream can still store it at all: an asset in the trash is absent from this and the trash is
      // undoable, so its decision has to survive being there.
      final storable = await _repository.detailsFor(ids);

      final rows = <OfflineFlagRow>[];
      final unselected = <OfflineFlagRow>[];
      for (final row in decided) {
        if (!storable.containsKey(row.id)) {
          continue;
        }
        final quality = policy.resolve(albums[row.id] ?? const []);
        if (quality == null) {
          unselected.add(row);
        } else if (quality != row.quality) {
          rows.add(
            OfflineFlagRow(
              id: row.id,
              quality: quality,
              isImage: row.isImage,
              hasMotion: row.hasMotion,
              createdAt: row.createdAt,
              touchedAt: at,
            ),
          );
        }
      }

      if (rows.isNotEmpty) {
        await _flags.set(rows);
        for (final row in rows) {
          _index.setWanted(row.id, row.quality, isImage: row.isImage, hasMotion: row.hasMotion);
        }
      }
      if (unselected.isNotEmpty) {
        await _flags.dropUnselected(unselected.map((row) => row.id));
        for (final row in unselected) {
          _index.setWanted(row.id, OfflineQuality.none, isImage: row.isImage);
        }
      }
    }
  }

  // --------------------------------------------------------------------------- Applying settings to photos that
  // already exist ---------------------------------------------------------------------------

  /// Applies [change] to the current selection and re-derives what it covers.
  Future<void> applyPolicy(OfflinePolicy Function(OfflinePolicy current) change) async {
    await _ready;

    final written = await _policyWrites.run<({OfflinePolicy next, int generation, DateTime touchedAt})?>(() async {
      final previous = policy;
      final next = change(previous);
      if (next == previous) {
        // A menu re-picking what it showed. Deriving would be inert but still page.
        return null;
      }
      await _writePolicy(next);
      // Stamped where the change is recorded rather than where it is derived, so the queue reflects the order the user
      // gave the instructions in even when a pass is superseded, deferred or retried.
      final touchedAt = DateTime.now();
      _recordUnapplied(next.library == previous.library ? _changedAlbums(previous, next) : null, touchedAt);
      return (next: next, generation: _policyGeneration, touchedAt: touchedAt);
    });

    if (written == null) {
      return;
    }
    final next = written.next;
    final generation = written.generation;

    var applied = false;
    await _exclusive(() async {
      // A later tap owns the work now, including the albums this call added.
      if (generation != _policyGeneration) {
        return;
      }
      final claimed = _takeUnapplied(written.touchedAt);
      final scope = claimed.albums;
      if (scope != null && scope.isEmpty) {
        return;
      }

      applied = await _deriveOrDefer(next, scope, claimed.at);
      // Rows read what is selected and what it left behind, so they have to be
      // told now rather than at the next download's coalesced bump.
      _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
    });

    if (!applied || generation != _policyGeneration) {
      return;
    }
    await _afterImperativeChange();
  }

  /// [_derive], handing the scope back if it does not finish. Losing it is invisible: policy only ever revisits assets
  /// that are *new*, so an album left un-derived would stay that way.
  Future<bool> _deriveOrDefer(OfflinePolicy policy, Set<String>? scope, DateTime touchedAt) async {
    try {
      await _derive(policy, scope, touchedAt);
      return true;
    } catch (error, stackTrace) {
      _recordUnapplied(scope, touchedAt);
      _log.warning('Could not apply the selection', error, stackTrace);
      _emit(_status.copyWith(lastError: 'Could not apply that change yet. It will be retried.'));
      return false;
    }
  }

  /// Re-derives `wanted` for [scope], or for the whole library when it is null.
  Future<void> _derive(OfflinePolicy next, Set<String>? scope, DateTime touchedAt) async {
    DateTime? cursorCreatedAt;
    String? cursorId;

    while (true) {
      final page = scope == null
          ? await _repository.allAssets(afterCreatedAt: cursorCreatedAt, afterId: cursorId, limit: _pageSize)
          : await _repository.assetsInAlbums(
              scope,
              afterCreatedAt: cursorCreatedAt,
              afterId: cursorId,
              limit: _pageSize,
            );
      if (page.isEmpty) {
        break;
      }
      cursorCreatedAt = page.last.createdAt;
      cursorId = page.last.id;

      final ids = page.map((candidate) => candidate.id).toList();
      final albums = await _repository.albumsOf(ids);
      // What is already recorded, so a walk that changes nothing writes nothing. This is what makes re-deriving the
      // *whole library* the answer to any mismatch the scoped paths cannot express: the cost is the rows that actually
      // move, not one write per asset, and `touched_at` keeps meaning "when the change that selected this was made"
      // rather than "when a walk last passed over it".
      final stored = await _flags.decisionsFor(ids);
      final rows = <OfflineFlagRow>[];
      final unselected = <OfflineCandidate>[];
      for (final candidate in page) {
        final quality = next.resolve(albums[candidate.id] ?? const []);
        if (quality == null) {
          unselected.add(candidate);
          continue;
        }
        final hasMotion = candidate.motionVideoId != null;
        final current = stored[candidate.id];
        if (current != null && current.quality == quality && current.hasMotion == hasMotion) {
          continue;
        }
        rows.add(
          OfflineFlagRow(
            id: candidate.id,
            quality: quality,
            isImage: candidate.isImage,
            hasMotion: hasMotion,
            createdAt: candidate.createdAt,
            touchedAt: touchedAt,
          ),
        );
      }

      await _flags.set(rows);
      await _flags.dropUnselected(unselected.map((candidate) => candidate.id));
      for (final row in rows) {
        _index.setWanted(row.id, row.quality, isImage: row.isImage, hasMotion: row.hasMotion);
      }
      for (final candidate in unselected) {
        // Its real type: the entry survives deselection when its files do, and
        // a video recorded as an image reads its badge off the wrong variant.
        _index.setWanted(candidate.id, OfflineQuality.none, isImage: candidate.isImage);
      }
    }

    if (scope == null) {
      // Policy has now seen the whole library, so the next incremental pass starts beyond it, with a tie-break id no
      // real id can exceed. A scoped walk saw one album and may not claim that.
      //
      // The maximum among *storable* assets, and not `signature().latestUpdate`, which is the maximum over every row:
      // the watermark is consumed by a query that filters to what can be stored, so taking it from the unfiltered
      // maximum parks it above storable assets that were never decided — and trashing a photo bumps its `updatedAt`, as
      // does the hidden motion half of every Live Photo, so the two maxima differ routinely rather than rarely.
      final latest = await _repository.latestStorableUpdate();
      await _flags.setPolicyWatermark(latest == null ? null : (latest, '￿'));
    }
  }

  /// How much of a set is already here, for an album row's own progress line.
  ({int wanted, int available}) progressOf(Iterable<String> assetIds) {
    var wanted = 0;
    var available = 0;
    for (final id in assetIds) {
      if (_index.wantedOf(id).isWanted) {
        wanted++;
        if (_index.availabilityOf(id).isAvailable) {
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
    final policy = this.policy;

    await _exclusive(() async {
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
            // errand's wider appetite lives in the `errands` table, where `filesFor` reads it.
            quality: selected ?? kOfflineErrandQuality,
            isImage: asset.isImage,
            hasMotion: asset.motionVideoId != null,
            createdAt: asset.createdAt,
            touchedAt: now,
            // A selection-derived row when one covers it: marking it a cache would make every file it has reclaimable,
            // the preview its album still asks for included.
            onDemand: selected == null,
          ),
        );
      }

      await _flags.set(rows);
      // Recorded here rather than left to the pass that would eventually notice, because this is the one path that
      // *creates* rows for items the camera roll holds, and the flag decides whether the copy this errand is about to
      // fetch counts as a spare. A row starts at "no local copy", so a selection covering the item at full quality
      // would file it as library until a pass corrected it — and that window is exactly when the user reaches for
      // *Remove offline*.
      await _flags.setLocalCopy({for (final asset in details.values) asset.id: asset.localCopyUsable});
      for (final asset in details.values) {
        _index.noteLocalCopy(asset.id, localCopy: asset.localCopyUsable);
      }
      // "Get me these now" is a claim on the next few minutes of bandwidth, not a preference, so it is marked as such:
      // the queue puts an errand before every standing decision, however recent that decision is (FORK.md §3.3). The
      // mark cannot be read off the row above — `on_demand` is false whenever a selection also covers the item, which is
      // exactly the case where the errand still has to jump the queue.
      await _flags.addErrands([for (final row in rows) row.id]);
      for (final row in rows) {
        _index.noteErrand(row.id, errand: true);
      }
      for (final row in rows) {
        _index.setWanted(
          row.id,
          row.quality,
          isImage: row.isImage,
          hasMotion: row.hasMotion,
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
    final policy = this.policy;

    await _exclusive(() async {
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
        rows.add(
          OfflineFlagRow(
            id: id,
            quality: quality,
            isImage: asset!.isImage,
            hasMotion: asset.motionVideoId != null,
            createdAt: asset.createdAt,
            touchedAt: now,
          ),
        );
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
        _index.setWanted(row.id, row.quality, isImage: row.isImage, hasMotion: row.hasMotion);
      }
      for (final id in forgotten) {
        _index.setWanted(id, OfflineQuality.none, isImage: details[id]?.isImage ?? true);
      }
      _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
    });
  }

  /// How the store's bytes divide between what a selection maintains, what is only cached, and what browsing left
  /// behind, for the overview on the offline screen.
  Future<OfflineStorage> storage() async {
    final storage = await _flags.storage();
    _browsingBytes = await offlineCacheSize();
    return storage.withBrowsing(_browsingBytes);
  }

  /// How much browsing may keep.
  Future<void> setCacheBudget(int bytes) async {
    await _settings.write(SettingsKey.offlineCacheBudget, bytes);
    await offlineSetCacheBudget(bytes);
    _browsingBytes = await offlineCacheSize();
    _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
  }

  /// The most the app may hold in total, or zero for no limit. Raising it lets downloading continue at once; lowering
  /// it stops it, and deletes nothing.
  Future<void> setStorageLimit(int bytes) async {
    await _settings.write(SettingsKey.offlineStorageLimit, bytes);
    _emit(_status.copyWith(isOverLimit: !_isUnderLimit()));
    if (_isUnderLimit()) {
      await sync();
    }
  }

  /// Empties the opportunistic region, and re-measures it.
  Future<void> clearBrowsingCache(Future<void> Function() clear) async {
    await clear();
    _browsingBytes = await offlineCacheSize();
    _emit(_countsOn(_status).copyWith(revision: _status.revision + 1));
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
  Future<void> freeUpSpace({
    Iterable<String>? assetIds,
    OfflineReclaim what = OfflineReclaim.notMaintained,
  }) async {
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
        final deleted = await offlineDeletePaths([
          for (final file in files) offlinePinnedPath(root, file.name),
          for (final file in files) offlineCachePath(root, file.name),
        ]);
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
    _signature = null;
    await sync();
  }

  // --------------------------------------------------------------------------- Passes

  /// [check], coalesced, for the events that say the remote side of the database moved.
  ///
  /// Upstream applies server state in bursts — a websocket batch is many assets — and [check] is three aggregates when
  /// nothing moved, so one pass a few seconds after the last event is the right cost. Without it the mirror learns only
  /// on resume: a photo taken and uploaded while the app stays open sits unmirrored, and so does an album deleted on
  /// the server.
  void checkSoon() {
    if (_checkTimer?.isActive ?? false) {
      return;
    }
    _checkTimer = Timer(const Duration(seconds: 3), () => unawaited(check()));
  }

  /// The cheap pass: apply policy to anything new, and stop unless something moved.
  Future<void> check({bool download = true}) async {
    await _ready;
    await _exclusive(() async {
      try {
        final signature = await _repository.signature();
        if (signature.assetCount == 0) {
          return;
        }

        await _applyPolicy();
        if (_unappliedLibrary || _unappliedAlbums.isNotEmpty) {
          final claimed = _takeUnapplied(DateTime.now());
          await _deriveOrDefer(policy, claimed.albums, claimed.at);
        }
        await _applyAlbumChanges();

        if (signature == _signature &&
            _flags.revision == _flagRevision &&
            offlineVideoForm() == _syncedVideoForm &&
            _status.lastError == null) {
          _log.fine('Nothing changed since the last pass');
          return;
        }
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
      final signature = await _repository.signature();
      final flagRevision = _flags.revision;

      if (signature.assetCount == 0 && _index.wantedAssets > 0) {
        // Photos are wanted and upstream has none: a database mid-repopulation
        // after a fresh install, a sync reset or a sign-out, not an instruction.
        _log.info('No assets known yet; leaving the mirror untouched');
        return;
      }

      _browsingBytes = await offlineCacheSize();
      final held = await _downloads.outstanding();

      // Bring what the downloader is holding back down to the window before deciding anything else. Its queue outlives
      // the process and it never re-orders it, so whatever an older pass — or the build before an update — handed over
      // would otherwise run ahead of everything this pass is about to learn.
      final excess = _queue
          .excess([for (final task in held) (id: task.taskId, priority: task.priority)])
          .toSet();
      if (excess.isNotEmpty) {
        await _downloads.cancel(excess);
        _log.info('Handed back ${excess.length} queued download(s) to make room for what comes first');
      }

      // Every id the downloader was holding, the ones just cancelled included: cancelling is asynchronous and the task
      // id is the file name, so re-enqueueing one of those names in this pass would race its own cancellation. They are
      // skipped here and picked up by the next pass, which each cancellation's own callback sets off.
      final inFlight = held.map((task) => task.taskId).toSet();
      final outstanding = [for (final task in held) if (!excess.contains(task.taskId)) task];
      final abandoned = await _flags.abandoned();
      final errands = await _flags.errands();
      // Everything the downloader is holding, the cancellations included: each of those still reports a final state, and
      // a count that had already written them off would be decremented twice and let the window overrun.
      _queue.resetOutstanding(held.length);
      _reportOutstanding(outstanding);

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

      // Rows whose idea of the camera roll has gone stale. It decides which band a full-size copy sits in, and the walk
      // above has just read the live answer for every row it looked at, so this is the one place it costs nothing.
      if (localCopyMoved.isNotEmpty) {
        await _flags.setLocalCopy(localCopyMoved);
        // The badge reads this from the index, so it has to move with the row or a deduplicated photo keeps drawing a
        // full-length track until the next launch reloads the index from disk.
        localCopyMoved.forEach((id, localCopy) => _index.noteLocalCopy(id, localCopy: localCopy));
        // And the tiles have to be told. This is the one thing that changes what a badge draws without any file
        // arriving or leaving, so nothing else here would bump the revision the badge watches.
        _emit(_status.copyWith(revision: _status.revision + 1));
        _log.info('${localCopyMoved.length} item(s) changed hands with the camera roll');
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
        final gone = [for (final id in walk.unresolved) if (!known.contains(id) || hidden.contains(id)) id];
        if (gone.isNotEmpty) {
          for (final id in gone) {
            unavailable -= _index.wantedFilesOf(id);
          }
          await _flags.forget(gone);
          await _loadIndex();
          _log.info('Forgot ${gone.length} decision(s) about items the mirror no longer keeps on their own');
        }
      }

      // The pages arrive in `wanted` order, which is per asset; the queue puts
      // them in the order they should be fetched.
      _queue.replace(found);

      // Every reason the queue is holding still comes from the queue itself, so the line cannot claim the mirror is
      // running while it is not: a pass that finds work, hands none over and says nothing reads exactly like a pass that
      // found nothing to do.
      final stopped = _queue.stoppedBecause;
      _log.info(
        'Pass: ${found.length} missing found, ${inFlight.length} with the downloader, ${abandoned.length} given up on'
        '${complete ? ', whole list read' : ', stopped at the budget'}'
        '${stopped == null ? '' : ', $stopped'}',
      );

      _emit(
        _countsOn(_status).copyWith(
          queued: _queue.queued,
          failed: await _flags.abandonedCount(),
          // Only a pass that read every row counted every one of them; a pass that stopped at its budget would report
          // a fraction of the figure and move the progress line for no reason.
          unavailable: walk.walkedAll ? unavailable : null,
          onDevice: walk.walkedAll ? walk.onDevice : null,
        ),
      );

      if (complete && download) {
        // Only a pass that reached the end saw the whole list, and only one allowed to enqueue acted on it. A pass that
        // merely looked must not silence the next one.
        _signature = signature;
        _flagRevision = flagRevision;
        _syncedVideoForm = offlineVideoForm();
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
        final isErrand = errands.contains(want.id);
        // The live answer, against what the row remembers. It is what puts a hand-saved full-size copy in the spares
        // band rather than in the library (`_unselectedOver`), and it cannot be joined to from there, so the row carries
        // it and this is where it is corrected.
        if (asset.localCopyUsable != want.localCopy) {
          localCopyMoved[want.id] = asset.localCopyUsable;
        }
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
        if (isErrand && awaited == 0) {
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
      final signature = await _repository.signature();
      if (signature.assetCount == 0) {
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
        final missing = [for (final want in wants) if (!details.containsKey(want.id)) want.id];
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
      // and half of another. This gate takes no override.
      final after = await _repository.signature();
      if (after != signature) {
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
        databasePath: _flags.path,
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
        _signature = null;
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

  /// The files an asset needs to be usable with no network: thumbnail and preview at every rung, for a photo and a
  /// video alike, plus the big file at the rung that names it (FORK.md §3.2).
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
      OfflineFile(
        getThumbnailUrlForRemoteId(asset.id, type: AssetMediaSize.preview, thumbhash: asset.thumbHash),
        OfflineVariant.preview,
      ),
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
    _progress[update.task.taskId] = (fraction: update.progress, at: DateTime.now());

    // Every quarter, so a slow file leaves a trail without a line per percent.
    if ((previous?.fraction ?? 0) ~/ 0.25 != update.progress ~/ 0.25 && update.progress > 0) {
      _log.fine('${(update.progress * 100).round()}% of ${_describe(update.task)}');
    }
  }

  void onTaskFinished(TaskStatusUpdate update) => unawaited(_onTaskFinished(update));

  Future<void> _onTaskFinished(TaskStatusUpdate update) async {
    _queue.noteFinished();

    final started = _outstandingSince.remove(update.task.taskId);
    if (_progress.remove(update.task.taskId) != null && started != null) {
      final seconds = DateTime.now().difference(started).inSeconds;
      _log.fine('${update.status.name} after ${seconds}s: ${_describe(update.task)}');
    }

    if (update.status == TaskStatus.complete) {
      final row = await _completedRow(update);
      if (row != null) {
        _bufferHeld(row);
      }
      unawaited(_flags.clearFailure(update.task.taskId));
    } else if (update.status == TaskStatus.failed || update.status == TaskStatus.notFound) {
      // A 404 is the server's answer, not a hiccup — an asset whose thumbnail it has not generated has no thumbhash
      // either, so the URL says `c=` and stays wrong until it does. Recorded like any other failure so the same backoff
      // applies: without it the pass asks again every time, for good. Abandoning cannot outlive the cause, because the
      // thumbhash is *in* the name, so the file it names is a different file once the server produces one.
      final reason = update.exception?.description ?? update.status.name;
      _log.warning('Download ${update.status.name}: ${_describe(update.task)} — $reason');
      await _flags.recordFailure(update.task.taskId);
      _emitSoon(_status.copyWith(failed: await _flags.abandonedCount()));
    } else if (update.status == TaskStatus.canceled) {
      // The mirror's own doing — a pass handing back what it had queued past the window, or a pause. Not a failure, and
      // there can be hundreds at once, so it is not worth a line each.
      _log.fine('Handed back: ${_describe(update.task)}');
    } else {
      _log.warning('Download ended as ${update.status.name}: ${_describe(update.task)}');
    }
    _emitSoon(_status.copyWith(queued: _queue.queued));

    unawaited(_queue.topUp());

    // The queue drained but the last pass stopped at its budget, so there is
    // more to look for.
    if (_queue.isIdle && _signature == null && !_isPaused) {
      unawaited(sync());
    }
  }

  /// What the downloader has been holding for too long, by name.
  ///
  /// A task that never reaches a final state — waiting for Wi-Fi, waiting to retry, dropped while the app was killed —
  /// calls nothing back, so it sits in the count with no other trace. Age is what separates that from a video that is
  /// simply large: two passes seconds apart always see the same running download, and saying so every time is noise.
  void _reportOutstanding(List<Task> outstanding) {
    final now = DateTime.now();
    final since = {for (final task in outstanding) task.taskId: _outstandingSince[task.taskId] ?? now};
    _outstandingSince = since;

    final stuck = outstanding.where((task) => now.difference(since[task.taskId]!) >= _stuckAfter).toList();
    if (stuck.isEmpty) {
      return;
    }
    _log.warning(
      '${stuck.length} download(s) outstanding for over ${_stuckAfter.inMinutes} minutes '
      '(Wi-Fi only: ${_settings.appConfig.offlineWifiOnly}): '
      '${stuck.take(10).map((task) => '${_describe(task)} ${_progressOf(task, now)}').join(', ')}'
      '${stuck.length > 10 ? ', …' : ''}',
    );

    // Cancelled rather than waited on any longer. A task the downloader holds but does not move — dropped when the app
    // was replaced, deferred by the system, or left behind something that never ended — reports nothing and ends
    // nothing, so it keeps one of the group's three slots for good. Cancelling ends it, which frees the slot, and the
    // next pass finds the file missing and asks again.
    final dead = [
      for (final task in stuck)
        if (_progress[task.taskId] == null || now.difference(_progress[task.taskId]!.at) >= _stuckAfter) task.taskId,
    ];
    if (dead.isEmpty) {
      return;
    }
    _log.warning('Cancelling ${dead.length} download(s) that have not moved; they will be fetched again');
    for (final id in dead) {
      _outstandingSince.remove(id);
      _progress.remove(id);
    }
    unawaited(_downloads.cancel(dead));
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
  String _describe(Task task) {
    final parts = task.metaData.split('|');
    final variant = parts.length == 3 ? OfflineVariant.values[int.tryParse(parts[1]) ?? 0].name : '?';
    return '${parts.first} $variant <${task.url}>';
  }

  Future<OfflineHeldRow?> _completedRow(TaskStatusUpdate update) async {
    final parts = update.task.metaData.split('|');
    if (parts.length != 3) {
      // Nothing can be written down about it, so it stays missing and is fetched again on the next pass, for good.
      _log.severe('Downloaded file has no usable metadata: ${update.task.taskId}');
      return null;
    }
    try {
      return OfflineHeldRow(
        name: update.task.taskId,
        assetId: parts[0],
        variant: OfflineVariant.values[int.parse(parts[1])],
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
  void _bufferHeld(OfflineHeldRow row, {bool isNewToStore = true}) {
    _index.markHeld(row.assetId, row.variant, row.token, row.size, isNewToStore: isNewToStore);
    _heldBuffer.add(row);
    _scheduleRevisionBump();
    _emitSoon(_countsOn(_status));

    if (_heldBuffer.length >= 100) {
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
    if (_heldBuffer.isEmpty) {
      return;
    }

    if (_reclaiming && !force) {
      // Deferred, not dropped: the pass can exit by exception and never reach
      // its own flush, and a file on disk with no row is fetched again.
      _heldTimer = Timer(const Duration(seconds: 2), () => unawaited(_flushHeld()));
      return;
    }

    final batch = List<OfflineHeldRow>.from(_heldBuffer);
    _heldBuffer.clear();
    await _flags.markHeld(batch);
    await offlineNoteStored([for (final row in batch) row.name]);
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
    _signature = null;
    await _downloads.cancelAll();
    _queue.clear();
    _emit(_status.copyWith(queued: 0));
  }

  /// Forgets which files gave up, so the next pass tries them again.
  Future<void> retryFailed() async {
    await _flags.forgetFailures();
    _signature = null;
    _emit(_status.copyWith(failed: 0));
    await sync();
  }

  /// Removes every stored file, the opportunistic region included, and stays paused.
  Future<void> deleteAll() async {
    await _ready;
    await _exclusive(() async {
      await _setPaused(true);
      _heldBuffer.clear();
      _heldTimer?.cancel();

      await offlineDeleteStore(await offlineStoreRoot());
      await _flags.clearHeld();
      _index.clearHeld();
      await offlineForgetIndex();

      _emit(_countsOn(_status).copyWith(failed: 0, revision: _status.revision + 1));
    });
  }

  Future<void> dispose() async {
    _emitTimer?.cancel();
    _revisionTimer?.cancel();
    _checkTimer?.cancel();
    // Last chance to write: deferring here would hand the work to a pass that
    // may outlive this object, through a timer holding it alive.
    await _flushHeld(force: true);
    _heldTimer?.cancel();
    await _statusController.close();
  }
}
