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
/// Deliberately small. The plugin runs three of the group at once and never re-orders what it already holds, so
/// everything handed over early is work the next few minutes are committed to: with a window of hundreds, a file asked
/// for by hand waits behind hundreds of previews whatever its priority says. A window of a couple of dozen is still far
/// more than three concurrent downloads can drain between completion callbacks, and it is what makes the ordering below
/// something the user can feel rather than something the queue merely believes.
const _maxOutstanding = 24;
const _topUpChunk = 12;

/// How long the mirror will give way to upstream's backup before handing work over anyway.
///
/// Long enough that an ordinary upload — a large video on a slow link — is never interrupted by the mirror competing for
/// the shared downloader. Short enough that a backup which cannot finish, and there is always one photo that cannot,
/// stops being able to hold the mirror still for the rest of the install's life.
const _maxYield = Duration(minutes: 2);

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

  /// A file the queue claimed from disk instead of fetching it. [isNewToStore] is false for one that was already in the
  /// mirror's own region, whose bytes are already counted.
  final void Function(OfflineHeldRow row, {required bool isNewToStore}) onHeld;

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
  bool _toppingUp = false;
  bool _topUpAgain = false;

  /// When the mirror started giving way to the backup, or null if it is not.
  DateTime? _yieldingSince;

  int get queued => _outstanding + _pending.length;

  bool get isIdle => _outstanding == 0 && _pending.isEmpty;

  /// What is waiting, for the integrity pass: a file about to be fetched must not be swept the moment it lands.
  Iterable<OfflineMissingFile> get entries => _pending;

  bool get _isPaused => _settings.appConfig.offlinePaused;

  /// Nothing more will be handed over: the user stopped it, the store is at its limit, or the backup is uploading. None
  /// of them deletes anything, and the last one clears itself.
  bool get _isStopped => _isPaused || !hasRoom() || _yieldingToBackup;

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
    return null;
  }

  /// Giving way to the backup, but never indefinitely.
  ///
  /// The courtesy is worth about as long as one upload takes; past that the backup is not transferring so much as
  /// failing, and a mirror that waits on it is a mirror that never runs again. The fallback is not "no protection" —
  /// every task the mirror enqueues sits below every upload in the shared holding queue, and its group concurrency caps
  /// it at three of the six slots — so past this the ordering alone is left to do the job it was built for.
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
  }

  /// Notes what the downloader is already holding, at the start of a pass.
  void resetOutstanding(int count) => _outstanding = count;

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

  void noteFinished() {
    if (_outstanding > 0) {
      _outstanding--;
    }
  }

  void clear() {
    _pending.clear();
    _outstanding = 0;
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
      } while (_topUpAgain || (!_isStopped && _pending.isNotEmpty && _outstanding < _maxOutstanding));
    } finally {
      _toppingUp = false;
    }
  }

  Future<void> _fill() async {
    final root = await offlineStoreRoot();

    while (!_isStopped && _pending.isNotEmpty && _outstanding < _maxOutstanding) {
      final room = (_maxOutstanding - _outstanding).clamp(0, _topUpChunk);
      final adoptions = <({OfflineHeldRow row, bool moved})>[];
      final downloads = <OfflineDownload>[];

      var movedBytes = 0;
      while (adoptions.length + downloads.length < room && _pending.isNotEmpty) {
        final entry = _pending.removeFirst();
        final adopted = offlineAdopt(root, entry.file.name);
        if (adopted == null) {
          downloads.add(OfflineDownload(assetId: entry.assetId, file: entry.file, isErrand: entry.isErrand));
          continue;
        }
        adoptions.add((row: _heldRow(entry, adopted.size), moved: adopted.moved));
        if (adopted.moved) {
          movedBytes += adopted.size;
        }
      }

      for (final adoption in adoptions) {
        // A file already in `pinned/` is already counted in the store's total;
        // only one that just moved out of the opportunistic region is new to it.
        onHeld(adoption.row, isNewToStore: adoption.moved);
      }
      if (movedBytes > 0) {
        unawaited(offlineNotePromoted(movedBytes));
      }
      if (downloads.isEmpty) {
        // A chunk of nothing but renames did no I/O to wait on, and would run
        // the whole queue down without yielding once.
        await Future<void>.delayed(Duration.zero);
        continue;
      }

      _outstanding += downloads.length;
      onChanged();
      final refused = await _downloads.enqueue(downloads, wifiOnly: _settings.appConfig.offlineWifiOnly);
      if (refused.isNotEmpty) {
        // They will never call back, so the count has to give them up here or it reports work that is not happening.
        _outstanding -= refused.length;
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
