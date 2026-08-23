/// immich-sync fork — the order files are fetched in, and how many at once (FORK.md §3.3). The service decides *what*
/// the phone should hold; this decides what to spend the next few minutes of bandwidth on, and hands it over in bounded
/// chunks.
library;

import 'dart:async';
import 'dart:collection';

import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_download.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

/// How many tasks the downloader holds at once, and how many are handed over at a time.
///
/// Large, because most of a library is small files: a thumbnail or a preview transfers in a fraction of the time its
/// task costs to schedule, so what decides the speed is keeping every one of the group's slots busy (`main.dart`), and
/// a window that drains in seconds leaves them idle while the next chunk is handed over — and stops downloading
/// altogether soon after iOS suspends the app, since nothing tops it up until it comes back. The cost is ordering: the
/// plugin never re-orders what it already holds, so a decision made a moment ago waits behind up to this many files.
/// Small files, so that is seconds. An errand does not wait at all — its priority puts it first inside the plugin too.
const _maxOutstanding = 200;
const _topUpChunk = 50;

/// How many full-size files — originals and videos — the downloader holds at once, out of [_maxOutstanding].
///
/// Those are bandwidth-bound rather than overhead-bound, so a deep queue of them buys nothing, and it costs: everything
/// handed over after them waits for them, and a video can take an hour. Two rounds of the group's concurrency keeps
/// every slot busy without committing the next hours to them.
const _maxOutstandingFullSize = 16;

/// How long the mirror will give way to upstream's backup before handing work over anyway.
///
/// Long enough that an ordinary upload — a large video on a slow link — is never interrupted by the mirror competing for
/// the shared downloader. Short enough that a backup which cannot finish, and there is always one photo that cannot,
/// stops being able to hold the mirror still for the rest of the install's life.
const _maxYield = Duration(minutes: 2);

/// How often a queue that has work but is not allowed to hand it over looks again.
///
/// Every reason [OfflineDownloadQueue._isStopped] gives clears on its own — the backup falls quiet, the courtesy window
/// expires, space is freed — and none of them announces it. Without a clock of its own the queue waits for whatever
/// event happens to wake the *service* next, which on a quiet phone is nothing at all: a plan made, nothing handed over,
/// and a screen that goes on saying files are on their way. This is what makes "stopped" a state the queue leaves by
/// itself rather than one the user has to shake it out of.
const _retryStopped = Duration(seconds: 30);

/// How long the queue holds off after a failure that says nothing about the file (`classifyOfflineFailure`), doubling
/// on each one that follows a resumption, up to the ceiling.
///
/// Such a failure — no network, a rejected session, a proxy with nothing behind it — is about to be true of every file
/// in the queue, and the files are not counted against for it. Without a pause the queue would hand the next batch
/// straight over to fail the same way, and the pass that follows would find them missing and hand them over again.
const _backoffStart = Duration(minutes: 1);
const _backoffMax = Duration(minutes: 30);

/// A file the mirror wants and does not have, waiting for room in the queue.
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

  /// Asked for by hand ("Save offline"), rather than maintained by a selection. An errand is a request for *these* files
  /// now, so it is the one thing that outranks a standing decision however recent that decision is.
  final bool isErrand;

  /// The two dates the queue is ordered by, carried from the `wanted` row so the ordering can be applied to a whole
  /// batch at once rather than per page.
  final int touchedAt;
  final int createdAt;

  /// The order (FORK.md §3.3): an errand, then the most recent decision, then the cheapest and most useful file within
  /// that decision, then the newest photo.
  ///
  /// Decision above the rungs is load-bearing, and the reason is a case people rely on: switching one album to full
  /// quality during a library-wide preview sync has to fetch *that album*, videos included, rather than joining the back
  /// of a hundred thousand previews. Cheap-first is what orders one decision internally, not what orders decisions
  /// against each other — and an errand needs neither, which is why it is a tier of its own rather than a key.
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
    required this.onChanged,
    required this.onRefused,
    required this.hasRoom,
    required this.isBackingUp,
  });

  final OfflineDownloadRepository _downloads;
  final SettingsRepository _settings;

  /// A file the queue claimed from disk instead of fetching it.
  final void Function(OfflineHeldRow row) onHeld;

  /// Something the status line reports has moved.
  final void Function() onChanged;

  /// Files the downloader would not take, which are not coming back on their own.
  final void Function(List<OfflineDownload> refused) onRefused;

  /// Whether the store is still under the storage limit. Asked before every chunk rather than once, since the answer
  /// moves as files land.
  final bool Function() hasRoom;

  /// Whether upstream's backup is **actively transferring**. The mirror yields to it: uploads are the user's only copy
  /// leaving the phone, downloads are a second copy coming back, and the two share one downloader — six tasks at a time,
  /// one host. Priority alone is not quite enough, because a queue the mirror keeps full is a queue the backup waits
  /// behind for as long as one of its own tasks takes.
  ///
  /// Activity, and not the backup's backlog: a photo the backup cannot upload stays in the backlog for ever, and
  /// yielding to *that* is a deadlock rather than a courtesy (see [_maxYield]).
  final bool Function() isBackingUp;

  final _pending = ListQueue<OfflineMissingFile>();
  int _outstanding = 0;

  /// How many of [_outstanding] are full-size files (see [_maxOutstandingFullSize]).
  int _outstandingFullSize = 0;
  bool _toppingUp = false;
  bool _topUpAgain = false;

  /// Set while work is waiting on a condition that clears itself (see [_retryStopped]).
  Timer? _retry;

  /// When the mirror started giving way to the backup, or null if it is not.
  DateTime? _yieldingSince;

  /// Until when nothing is handed over after a transient failure, and how long the next one will hold off.
  DateTime? _backingOffUntil;
  Duration _backoff = _backoffStart;

  /// Files the downloader is holding. What "downloading" may honestly be said about.
  int get queued => _outstanding;

  /// Files planned and not yet handed over. Nothing is moving for these, so they are counted apart
  /// (`offline.model.dart`).
  int get pending => _pending.length;

  bool get isIdle => _outstanding == 0 && _pending.isEmpty;

  /// What is waiting, for the integrity pass: a file about to be fetched must not be swept the moment it lands.
  Iterable<OfflineMissingFile> get entries => _pending;

  bool get _isPaused => _settings.appConfig.offlinePaused;

  /// Nothing more will be handed over: the user stopped it, the store is at its limit, or the backup is uploading. None
  /// of them deletes anything, and the last one clears itself.
  bool get _isStopped => _isPaused || !hasRoom() || _yieldingToBackup || _backingOff;

  /// Why nothing is being handed over, for the log. A pass that hands nothing over and says nothing about it is
  /// indistinguishable from a pass that found nothing to do, which is how a stopped queue goes unnoticed.
  String? get stoppedBecause {
    if (_isPaused) {
      return 'paused';
    }
    if (!hasRoom()) {
      return 'at the storage limit';
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

  /// A download failed for a reason that is not the file's. Holds hand-overs off for a while, and for longer each time
  /// the reason is still there when they resume.
  ///
  /// Ignored while already holding off: the tasks still with the downloader fail one after another for the same reason,
  /// and each of them doubling the wait would turn one outage into the ceiling at once.
  void backOff() {
    if (_backingOff) {
      return;
    }
    _backingOffUntil = DateTime.now().add(_backoff);
    final next = _backoff * 2;
    _backoff = next > _backoffMax ? _backoffMax : next;
  }

  /// A download arrived, so whatever made the queue hold off has passed.
  void noteSucceeded() {
    _backingOffUntil = null;
    _backoff = _backoffStart;
  }

  /// Giving way to the backup, but never indefinitely.
  ///
  /// The courtesy is worth about as long as one upload takes; past that the backup is not transferring so much as
  /// failing, and a mirror that waits on it is a mirror that never runs again. The fallback is not "no protection" —
  /// every task the mirror enqueues sits below every upload in the shared holding queue, and its group concurrency caps
  /// it at eight of the sixteen slots — so past this the ordering alone is left to do the job it was built for.
  bool get _yieldingToBackup {
    if (!isBackingUp()) {
      _yieldingSince = null;
      return false;
    }
    final since = _yieldingSince ??= DateTime.now();
    return DateTime.now().difference(since) < _maxYield;
  }

  /// Replaces what is waiting, in the order it should be fetched. Tasks already handed to the downloader keep their
  /// place: re-deciding them would cancel work that is already spending the data.
  void replace(List<OfflineMissingFile> found) {
    found.sort(OfflineMissingFile.compare);
    _pending
      ..clear()
      ..addAll(found);
    // A plan with nothing left in it has nothing to wait for; one that arrives while a retry is pending keeps it.
    if (_pending.isEmpty) {
      _cancelRetry();
    }
  }

  /// Notes what the downloader is already holding, at the start of a pass: [count] tasks, [fullSize] of them full-size.
  void resetOutstanding(int count, {int fullSize = 0}) {
    _outstanding = count;
    _outstandingFullSize = fullSize;
  }

  /// Which of the tasks the downloader is holding to give back, because it is holding more than the window.
  ///
  /// The window is only a promise about *ordering* if it is enforced on what is already over there. The plugin never
  /// re-orders its own queue, so a window filled by an earlier pass — or by the build before an app update, since the
  /// plugin's queue outlives the process — is hundreds of files of latency in front of anything learned since. Nothing
  /// is lost by handing them back: the next pass finds their files missing and asks again, in the order that pass
  /// decides. The worst priority goes first, so what is given back is what would have run last anyway.
  List<String> excess(Iterable<({String id, int priority})> held) {
    final ordered = held.toList()..sort((a, b) => b.priority.compareTo(a.priority));
    final over = ordered.length - _maxOutstanding;
    return over <= 0 ? const [] : [for (final task in ordered.take(over)) task.id];
  }

  void noteFinished({bool fullSize = false}) {
    if (_outstanding > 0) {
      _outstanding--;
    }
    if (fullSize && _outstandingFullSize > 0) {
      _outstandingFullSize--;
    }
  }

  /// Whether the next file waits for a full-size slot to free up. Only the head of the queue is asked: what is behind it
  /// is fetched after it, so skipping ahead would undo the order the pass decided.
  bool get _waitingForFullSizeSlot =>
      _pending.isNotEmpty &&
      _pending.first.file.variant.isFullSize &&
      _outstandingFullSize >= _maxOutstandingFullSize;

  /// Whether anything more may be handed over right now.
  bool get _canHandOver =>
      !_isStopped && _pending.isNotEmpty && _outstanding < _maxOutstanding && !_waitingForFullSizeSlot;

  void clear() {
    _pending.clear();
    _outstanding = 0;
    _outstandingFullSize = 0;
    _cancelRetry();
  }

  /// Stops the clock, for a service being torn down.
  void dispose() => _cancelRetry();

  void _cancelRetry() {
    _retry?.cancel();
    _retry = null;
  }

  /// Comes back for work that could not be handed over, since nothing announces that the reason has passed.
  ///
  /// Not while paused. That is the one stop with a way out that says so — the switch the user turned off resumes
  /// through `setPaused`, which asks for a pass of its own — so a clock here would only spend a wake-up every half a
  /// minute deciding to do nothing, for as long as downloading stays off.
  void _retryLater() {
    if (_isPaused || (_retry?.isActive ?? false)) {
      return;
    }
    _retry = Timer(_retryStopped, () {
      _retry = null;
      if (_pending.isEmpty) {
        return;
      }
      unawaited(topUp());
    });
  }

  /// Hands the next batch to the downloader, claiming whatever the device already has instead of asking for it twice.
  Future<void> topUp() async {
    if (_toppingUp) {
      _topUpAgain = true;
      return;
    }
    _toppingUp = true;
    try {
      // Until the queue is full or there is nothing left, rather than once per wake-up: [_fill] hands over one chunk
      // and returns, and stopping there would leave the queue short whenever `_topUpChunk` is below `_maxOutstanding`.
      do {
        _topUpAgain = false;
        await _fill();
      } while (_topUpAgain || _canHandOver);
    } finally {
      _toppingUp = false;
      // Work left over with nothing running for it is the shape every parked queue takes, whatever parked it: stopped
      // by a condition that clears silently, or simply planned by a pass that was not allowed to download. Either way
      // the only thing that moves it is a clock of this queue's own.
      if (_pending.isNotEmpty && _outstanding == 0 && !_isPaused) {
        _retryLater();
      } else {
        _cancelRetry();
      }
      onChanged();
    }
  }

  Future<void> _fill() async {
    final root = await offlineStoreRoot();

    while (_canHandOver) {
      final room = (_maxOutstanding - _outstanding).clamp(0, _topUpChunk);
      final adoptions = <OfflineHeldRow>[];
      final downloads = <OfflineDownload>[];
      var fullSize = 0;

      while (adoptions.length + downloads.length < room && _pending.isNotEmpty) {
        final entry = _pending.first;
        // A file already on disk is claimed whatever its size: it takes no slot.
        final size = offlineAdopt(root, entry.file.name);
        if (size != null) {
          _pending.removeFirst();
          adoptions.add(_heldRow(entry, size));
          continue;
        }
        if (entry.file.variant.isFullSize) {
          if (_outstandingFullSize + fullSize >= _maxOutstandingFullSize) {
            break;
          }
          fullSize++;
        }
        _pending.removeFirst();
        downloads.add(OfflineDownload(assetId: entry.assetId, file: entry.file, isErrand: entry.isErrand));
      }

      for (final row in adoptions) {
        // Counted unless the store already records it: a file the image path kept and has not reported yet is in no
        // total, and the report that follows finds it held and adds nothing.
        onHeld(row);
      }
      if (downloads.isEmpty) {
        // A chunk of nothing but claims did no I/O to wait on, and would run
        // the whole queue down without yielding once.
        await Future<void>.delayed(Duration.zero);
        continue;
      }

      _outstanding += downloads.length;
      _outstandingFullSize += fullSize;
      onChanged();
      final refused = await _downloads.enqueue(downloads, wifiOnly: _settings.appConfig.offlineWifiOnly);
      if (refused.isNotEmpty) {
        // They will never call back, so the count has to give them up here or it reports work that is not happening.
        _outstanding -= refused.length;
        _outstandingFullSize -= refused.where((download) => download.file.variant.isFullSize).length;
        onRefused(refused);
        onChanged();
      }
      return;
    }
  }

  OfflineHeldRow _heldRow(OfflineMissingFile entry, int size) => OfflineHeldRow(
    name: entry.file.name,
    assetId: entry.assetId,
    variant: entry.file.variant,
    token: entry.file.token,
    size: size,
  );
}
