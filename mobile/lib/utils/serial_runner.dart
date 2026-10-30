import 'dart:async';

/// immich-sync fork: runs one thing at a time, and queues at most one more behind it.
///
/// This exists because drift answers a write to a watched table by *cancelling* the query in flight and starting it
/// again from the top (`stream_queries.dart`, `QueryStream._onListenOrResume`). That cancellation is cooperative — a
/// `CancellationToken` sets a flag, and nothing in it can reach a statement SQLite has already begun — so the
/// abandoned run performs its whole read anyway and only its result is discarded.
///
/// For a statement costing a page or two that is invisible. For the timeline's bucket query on a large library it is
/// not: the query counts every asset by day, which is 145 MB of scattered page reads on a 532,068-asset library and
/// seconds of work. Writes to the tables it reads arrive far faster than that — hashing commits once per 32 photos,
/// and a first sync commits once per 5,000-event chunk for as long as the download lasts — so the query is restarted
/// before it can ever finish. Not slowly: *never*, for the whole duration of the sync. That is the shape of upstream's
/// "never able to finish Building the timeline".
///
/// Rate-limiting the invalidations cannot fix that, whatever the rate: any window shorter than the query still lands
/// inside it, and a window long enough to be safe would have to be longer than the slowest query on the largest
/// library, which is not a number anyone knows. What is needed is not a lower rate but a guarantee of *progress*, and
/// that is all this is:
///
///   * nothing is ever cancelled — a run that has started always finishes;
///   * while one is running, a caller does not start a competing one;
///   * a caller that arrives during a run is answered by exactly one further run *after* it, because whatever prompted
///     them arrived after the running one began and so is not reflected in its result;
///   * and callers arriving during that wait all share that one further run, so the queue can never exceed one.
///
/// Work becomes one run per generation instead of one per write, and the total is bounded by how long a run takes
/// rather than by how often the database is written.
///
/// The queued run is shared by every caller that joins it, so it must not belong to any one of them. It runs in the
/// zone the runner was created in, not the zone of the caller that happened to queue it: drift fetches each watched
/// query inside a cancellation zone, and a queued run started from one would throw `CancellationException` at drift's
/// next `checkIfCancelled()` once that caller is cancelled — which drift does to every fetch the next write supersedes.
/// Every caller still sharing the run would then get nothing at all.
class SerialRunner<T> {
  /// Where shared runs execute; see the class comment. Create the runner outside any drift fetch.
  final Zone _zone = Zone.current;

  Future<T>? _inFlight;
  Future<T>? _queued;

  /// True while a run is outstanding. For tests and for reasoning; nothing needs it to decide anything.
  bool get isRunning => _inFlight != null;

  /// Runs [body], or joins the queue for the run that will follow the one already going.
  Future<T> run(Future<T> Function() body) {
    final inFlight = _inFlight;
    if (inFlight == null) {
      // A run has just finished but the queued one has not started yet: `_inFlight` is cleared when a run completes,
      // and the queued run starts a microtask or two later. Joining it keeps "one running, at most one queued" true
      // across that gap instead of starting a second run beside it.
      return _queued ?? _start(body);
    }
    return _queued ??= _zone.run<Future<T>>(() => _afterCurrent(inFlight, body));
  }

  Future<T> _afterCurrent(Future<T> inFlight, Future<T> Function() body) async {
    // How the outstanding run ended is not this one's business: it is being made precisely because that result is out
    // of date, and an error in it is reported to whoever asked for it.
    await inFlight.then<void>((_) {}, onError: (_, _) {});
    // Cleared before starting, so anything arriving from here on queues behind the new run rather than joining this
    // one — which is already committed to reading a database that may have moved again since.
    _queued = null;
    return _start(body);
  }

  Future<T> _start(Future<T> Function() body) {
    final Future<T> started;
    try {
      started = body();
    } catch (error, stack) {
      // A body that throws synchronously must not leave the runner wedged with an in-flight run that will never
      // complete, which would queue every later caller behind nothing at all.
      return Future.error(error, stack);
    }
    _inFlight = started;
    return started.whenComplete(() {
      if (identical(_inFlight, started)) {
        _inFlight = null;
      }
    });
  }
}
