/// immich-sync fork: the one owner of what the store holds. Four records describe it: the files under `pinned/`, the
/// `held` rows, the in-memory [OfflineIndex] and the native lookup sets. Every change to one of them goes through here,
/// so a new path cannot update one and forget another.
library;

import 'dart:async';

import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/utils/offline_index.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/utils/async_mutex.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:immich_mobile/utils/offline_reclaim.dart';
import 'package:logging/logging.dart';

/// Arrivals written to `held` at once; more than this are written straight away.
const _batch = 100;
const _flushDelay = Duration(seconds: 2);
const _retryFirst = Duration(seconds: 2);
const _retryLimit = Duration(minutes: 1);

/// What the store was when an arrival was first noticed, before any wait. A wipe makes every earlier ticket stale, so a
/// file noticed before it is never recorded after it, however long the caller took in between.
final class OfflineLedgerTicket {
  const OfflineLedgerTicket._(this._generation);

  final int _generation;
}

class OfflineLedger {
  OfflineLedger(this._flags, this._index, {required this.onRecorded});

  final OfflineFlagsRepository _flags;
  final OfflineIndex _index;
  final _log = Logger('OfflineLedger');

  /// Files were written to `held`, so the store may now be over its limit.
  final void Function() onRecorded;

  /// Arrived files not yet in `held`: buffered, or being written. The index is `held` plus these, so a reload replays
  /// them; [_lock] keeps a reload from reading `held` in the middle of a write.
  final _buffer = <OfflineHeldRow>[];
  List<OfflineHeldRow> _writing = const [];
  final _lock = AsyncMutex();
  Timer? _timer;
  Duration? _retry;

  /// Stored files served since the last write; their `used_at` is what eviction orders by.
  final _reads = <String>{};

  /// Bumped by [wipe], which makes every [OfflineLedgerTicket] taken before it stale.
  int _generation = 0;

  /// While the integrity pass rewrites `held` on its own connection, arrivals wait.
  bool _walking = false;

  /// Taken when an arrival is first noticed, before anything is awaited, and handed to [record].
  OfflineLedgerTicket ticket() => OfflineLedgerTicket._(_generation);

  // Arriving.

  /// A file arrived: counted at once, written to `held` with the next batch. Dropped when a wipe came after [ticket].
  void record(OfflineHeldRow row, OfflineLedgerTicket ticket) {
    if (ticket._generation != _generation) {
      return;
    }
    _index.markHeld(row.assetId, row.variant, row.token, row.size);
    _buffer.add(row);
    if (_buffer.length >= _batch && _retry == null) {
      unawaited(flush());
      return;
    }
    _timer ??= Timer(_flushDelay, () => unawaited(flush()));
  }

  /// A stored file was served.
  void noteRead(String name) {
    _reads.add(name);
    if (_retry == null) {
      _timer ??= Timer(_flushDelay, () => unawaited(flush()));
    }
  }

  /// Writes what arrived and what was served, deletes the older versions the arrivals replace, and tells the native
  /// side. [force] writes even during the integrity pass, for when there will be no later chance.
  Future<void> flush({bool force = false}) async {
    _timer?.cancel();
    _timer = null;
    if (_buffer.isEmpty && _reads.isEmpty) {
      return;
    }

    if (_walking && !force) {
      // Deferred, not dropped: the pass may exit early and never reach its own flush.
      _timer = Timer(_flushDelay, () => unawaited(flush()));
      return;
    }

    final generation = _generation;
    final reads = _reads.toList();
    _reads.clear();
    // Taken and written under the lock, so a reload sees each row either unwritten or written, superseded files
    // included.
    final batch = <OfflineHeldRow>[];
    final superseded = await _lock.run(() async {
      batch.addAll(_buffer);
      _buffer.clear();
      if (batch.isEmpty) {
        return const <({String name, int size})>[];
      }
      _writing = batch;
      try {
        final superseded = await _flags.markHeld(batch);
        if (generation == _generation) {
          // The index counted the new files on arrival; it lets go of the old versions' bytes now that they are gone.
          _index.dropSupersededBytes(superseded.fold(0, (sum, file) => sum + file.size));
        }
        return superseded;
      } catch (error, stack) {
        // Put back, not dropped: the files are on disk and already counted.
        if (generation != _generation) {
          return null;
        }
        final retry = _retry == null ? _retryFirst : (_retry! * 2 > _retryLimit ? _retryLimit : _retry! * 2);
        _retry = retry;
        _log.warning(
          'Could not record ${batch.length} downloaded file(s); will retry in ${retry.inSeconds}s',
          error,
          stack,
        );
        _buffer.insertAll(0, batch);
        _timer?.cancel();
        _timer = Timer(retry, () => unawaited(flush()));
        return null;
      } finally {
        _writing = const [];
      }
    });
    if (superseded == null) {
      // Kept for the retry like the batch, so eviction does not take files just viewed for cold ones.
      if (generation == _generation) {
        _reads.addAll(reads);
      }
      return;
    }
    _retry = null;
    if (generation != _generation) {
      return;
    }
    if (reads.isNotEmpty) {
      try {
        await _flags.touchHeld(reads, DateTime.now());
      } catch (error) {
        _log.fine('Could not record ${reads.length} use(s) of stored files', error);
        // Written with the next flush; a wipe meanwhile forgets them.
        if (generation == _generation) {
          _reads.addAll(reads);
        }
      }
    }
    if (superseded.isNotEmpty) {
      // Older versions of files that just arrived; their rows are gone, so the files go now.
      await discard([for (final file in superseded) file.name], why: 'superseded');
    }
    if (batch.isEmpty) {
      return;
    }
    try {
      await offlineNoteStored([for (final row in batch) row.name]);
    } catch (error, stack) {
      _log.warning('Could not tell the store about ${batch.length} downloaded file(s)', error, stack);
    }
    onRecorded();
  }

  /// Reads `held` into the index again, replaying what is not written yet.
  Future<void> reload() => _lock.run(() async {
    final rows = await _flags.loadIndex();
    _index.load(rows, heldBytes: await _flags.heldBytes());
    for (final row in [..._writing, ..._buffer]) {
      _index.markHeld(row.assetId, row.variant, row.token, row.size, sample: false);
    }
  });

  // Removing.

  /// Deletes files that have rows, from every record. Returns how many could not be deleted from disk, which the
  /// integrity pass retries.
  Future<int> remove(List<OfflineHeldRow> files) async {
    if (files.isEmpty) {
      return 0;
    }
    final root = await offlineStoreRoot();
    // On another isolate, which keeps the screen responsive.
    final deleted = await offlineDeletePaths([for (final file in files) offlinePinnedPath(root, file.name)]);
    final names = [for (final file in files) file.name];
    // Under the lock, so a reload never reads rows the index has already let go of.
    await _lock.run(() async {
      for (final file in files) {
        _index.dropHeld(file.assetId, file.variant, file.size);
      }
      await _flags.dropHeld(names);
    });
    await offlineNoteRemoved(names);
    return deleted.failed;
  }

  /// Deletes files that have no row, such as superseded versions or files of locked items, from disk and the native
  /// sets.
  Future<void> discard(List<String> names, {required String why}) async {
    if (names.isEmpty) {
      return;
    }
    try {
      final root = await offlineStoreRoot();
      final deleted = await offlineDeletePaths([for (final name in names) offlinePinnedPath(root, name)]);
      if (deleted.failed > 0) {
        _log.warning('${deleted.failed} $why file(s) could not be deleted; the integrity pass will retry them');
      }
      await offlineNoteRemoved(names);
    } catch (error, stack) {
      _log.warning('Could not remove ${names.length} $why file(s)', error, stack);
    }
  }

  /// Runs the integrity pass, which deletes on its own isolate and rewrites `held` on its own connection, then
  /// rebuilds the native sets from what it left. [changed] says how many files the walk deleted or moved.
  Future<T> walk<T>(Future<T> Function() walk, {required int Function(T result) changed}) async {
    await flush();
    _walking = true;
    final T result;
    try {
      result = await walk();
    } finally {
      _walking = false;
    }
    await flush();
    if (changed(result) > 0) {
      await offlineForgetIndex();
    }
    return result;
  }

  /// Removes every file. [forgetSelection] also clears the decisions; otherwise only what is held goes. [stop] runs
  /// once arrivals no longer count, before the files go.
  Future<void> wipe({required bool forgetSelection, required Future<void> Function() stop}) async {
    // First, so a download finishing meanwhile is not recorded.
    _generation++;
    await stop();
    _clearPending();
    await offlineDeleteStore(await offlineStoreRoot());
    // Again, now the files are gone: deleting a large store takes seconds.
    _generation++;
    await _lock.run(() async {
      _clearPending();
      if (forgetSelection) {
        await _flags.clearAll();
        _index.clear();
      } else {
        await _flags.clearHeld();
        _index.clearHeld();
      }
    });
    await offlineForgetIndex();
  }

  void _clearPending() {
    _buffer.clear();
    _reads.clear();
    _timer?.cancel();
    _timer = null;
    _retry = null;
  }

  Future<void> dispose() async {
    await flush(force: true);
    _timer?.cancel();
  }
}
