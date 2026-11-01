/// immich-sync fork: how many small files download at once. Additive increase, multiplicative decrease, as in TCP and
/// Netflix's `concurrency-limits`: one more slot after a full round of quick successes, and a cut when the server
/// shows strain. That finds what the server and the network can take, instead of a fixed number that is too many for a
/// home server and too few behind HTTP/2.
library;

import 'dart:math' as math;

class OfflineConcurrencyLimit {
  OfflineConcurrencyLimit({
    this.initial = 6,
    this.min = 2,
    this.max = 16,
    this.slowAfter = const Duration(seconds: 10),
  }) : assert(min >= 1 && min <= initial && initial <= max),
       _limit = initial;

  /// Six, as browsers open per host over HTTP/1.1.
  final int initial;
  final int min;

  /// Past this, more parallel requests only queue on the server.
  final int max;

  /// A small file that takes longer than this says the server or the link is saturated, well before anything times
  /// out.
  final Duration slowAfter;

  int _limit;
  int _successes = 0;
  int _nextTicket = 0;

  /// Requests started before the last cut. Their failures describe the old limit, so they do not cut again: a server
  /// that drops every running request at once halves the limit once, not once per request.
  int _cutBefore = 0;

  int get limit => _limit;

  /// Taken when a request starts and handed back with its outcome.
  int start() => _nextTicket++;

  void onSuccess(int ticket, Duration took) {
    if (took > slowAfter) {
      _cut(ticket, 0.75);
      return;
    }
    if (++_successes >= _limit) {
      _successes = 0;
      _limit = math.min(max, _limit + 1);
    }
  }

  /// A failure that is not the file's own: a timeout, a dropped connection, an overloaded server.
  void onTransientFailure(int ticket) => _cut(ticket, 0.5);

  void _cut(int ticket, double factor) {
    if (ticket < _cutBefore) {
      return;
    }
    _cutBefore = _nextTicket;
    _successes = 0;
    _limit = math.max(min, (_limit * factor).floor());
  }
}
