/// immich-sync fork: whether a pass is due. A pass reads upstream's tables, the camera roll and the decisions, and is
/// only skipped when none of them moved since one settled. The rules for when a pass may settle live here, so they are
/// in one place and can be tested on their own.
library;

/// What a pass saw when it started, to tell afterwards whether a write overtook it.
class OfflinePassStart {
  const OfflinePassStart._(this._localMoved, this._localWrites, this._upstreamWrites, this._letGoClaimed);

  final bool _localMoved;
  final int _localWrites;
  final int _upstreamWrites;
  final bool _letGoClaimed;
}

class OfflineChanges {
  /// Whether upstream's tables were written since a pass last read them. Watching writes rather than column values is
  /// what catches in-place changes such as an edit being reverted, which move no count and no `updated_at`. Set until
  /// the first pass settles.
  bool _upstreamMoved = true;

  /// How many upstream writes this process has seen. A pass compares it before and after to know whether the tables
  /// moved underneath it; the flag alone cannot tell, since it is usually already set.
  int _upstreamWrites = 0;

  /// Whether the camera roll was written since a pass last read it. Hashing changes no row count but decides whether
  /// the camera roll holds an item (a checksum match), and with it whether the mirror needs the full-size file.
  bool _localMoved = true;
  int _localWrites = 0;

  /// The queue dropped files a pass may still want, after failures that are not their own.
  bool _letGo = false;

  /// What the last settled pass was based on.
  int? _settledRevision;
  String? _settledVideoForm;

  /// A camera-roll write, once the writes settle.
  void noteLocal() {
    _localMoved = true;
    _localWrites++;
  }

  /// An upstream write, counted as it happens: the integrity pass needs to know the table moved during its walk.
  void noteUpstreamWrite() => _upstreamWrites++;

  /// Upstream's writes settled, so a pass should read them.
  void noteUpstream() {
    _upstreamMoved = true;
    _upstreamWrites++;
  }

  /// Something other than a table write calls for a full pass: a user action, a wipe, a retry, upstream becoming
  /// complete.
  void invalidate() => _upstreamMoved = true;

  /// The queue let files go that only a pass can bring back.
  void noteLetGo() => _letGo = true;

  /// Whether the queue running dry should start a pass.
  bool get wantsPass => _upstreamMoved || _letGo;

  /// Whether a pass would find nothing new, given the decisions' [revision] and the video form now.
  bool isSettled({required int revision, required String videoForm}) =>
      !_upstreamMoved && !_letGo && !_localMoved && revision == _settledRevision && videoForm == _settledVideoForm;

  /// Taken as a pass starts. A pass that will enqueue claims the let-go mark; a pass that fails gives it back.
  OfflinePassStart begin({required bool download}) {
    final claimed = download && _letGo;
    if (download) {
      _letGo = false;
    }
    return OfflinePassStart._(_localMoved, _localWrites, _upstreamWrites, claimed);
  }

  /// Whether upstream's tables were written since [start].
  bool upstreamMovedSince(OfflinePassStart start) => _upstreamWrites != start._upstreamWrites;

  /// Ends a pass that ran to the end. It settles only if it read every row ([walkedAll]), everything fitted
  /// ([complete]), it could enqueue ([download]), upstream is not half-synced, and no write overtook it; otherwise the
  /// next check runs again. Any full walk re-read the camera roll for every row.
  void finish(
    OfflinePassStart start, {
    required bool walkedAll,
    required bool complete,
    required bool download,
    required bool upstreamComplete,
    required int revision,
    required String videoForm,
  }) {
    if (walkedAll && start._localMoved && _localWrites == start._localWrites) {
      _localMoved = false;
    }
    if (complete && download && upstreamComplete && !upstreamMovedSince(start)) {
      _upstreamMoved = false;
      // As of now, so the pass's own writes do not call for another. Every other write to the decisions takes the
      // same lock, so none can have slipped in.
      _settledRevision = revision;
      _settledVideoForm = videoForm;
    } else {
      _upstreamMoved = true;
    }
  }

  /// Ends a pass that failed: the let-go mark it claimed is given back.
  void fail(OfflinePassStart start) => _letGo = _letGo || start._letGoClaimed;
}
