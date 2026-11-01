/// immich-sync fork: the small-file lane's adaptive limit.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/utils/offline_concurrency.dart';

void main() {
  const quick = Duration(milliseconds: 200);
  const slow = Duration(seconds: 11);

  test('starts at six and grows by one per round of quick successes, up to the ceiling', () {
    final limit = OfflineConcurrencyLimit(max: 8);
    expect(limit.limit, 6);

    for (var i = 0; i < 5; i++) {
      limit.onSuccess(limit.start(), quick);
    }
    expect(limit.limit, 6);
    limit.onSuccess(limit.start(), quick);
    expect(limit.limit, 7);

    for (var i = 0; i < 100; i++) {
      limit.onSuccess(limit.start(), quick);
    }
    expect(limit.limit, 8);
  });

  test('halves on a network failure and never drops below the floor', () {
    final limit = OfflineConcurrencyLimit(initial: 8, min: 2);
    limit.onTransientFailure(limit.start());
    expect(limit.limit, 4);
    limit.onTransientFailure(limit.start());
    limit.onTransientFailure(limit.start());
    expect(limit.limit, 2);
  });

  test('a slow success cuts more gently than a failure', () {
    final limit = OfflineConcurrencyLimit(initial: 8);
    limit.onSuccess(limit.start(), slow);
    expect(limit.limit, 6);
  });

  test('requests started before a cut do not cut again', () {
    final limit = OfflineConcurrencyLimit(initial: 16);
    // Sixteen in flight when the server drops them all.
    final tickets = [for (var i = 0; i < 16; i++) limit.start()];
    for (final ticket in tickets) {
      limit.onTransientFailure(ticket);
    }
    expect(limit.limit, 8);

    // A request started after the cut is news again.
    limit.onTransientFailure(limit.start());
    expect(limit.limit, 4);
  });
}
