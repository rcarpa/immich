/// immich-sync fork — the guarantee the timeline's bucket query needs: a run that starts, finishes.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/serial_runner.dart';

void main() {
  late SerialRunner<int> sut;
  late List<Completer<int>> started;

  /// A body that never completes on its own, so a test decides exactly when each run ends.
  Future<int> body() {
    final completer = Completer<int>();
    started.add(completer);
    return completer.future;
  }

  setUp(() {
    sut = SerialRunner<int>();
    started = [];
  });

  test('the first caller runs immediately', () async {
    final first = sut.run(body);

    expect(started, hasLength(1));
    started[0].complete(7);

    expect(await first, 7);
    expect(sut.isRunning, isFalse);
  });

  test('a caller arriving mid-run does not start a second one', () async {
    unawaited(sut.run(body));
    unawaited(sut.run(body));

    expect(started, hasLength(1), reason: 'the second caller must wait, not race the first');
  });

  test('however many arrive mid-run, exactly one further run follows', () async {
    final first = sut.run(body);
    final waiting = [for (var i = 0; i < 5; i++) sut.run(body)];

    expect(started, hasLength(1));

    started[0].complete(1);
    await first;
    await pumpEventQueue();

    expect(started, hasLength(2), reason: 'five waiting callers must share one re-run, not queue five');

    started[1].complete(2);
    expect(await Future.wait(waiting), everyElement(2));
  });

  test('a caller arriving during the queued run waits for a third, not the second', () async {
    final first = sut.run(body);
    final second = sut.run(body);

    started[0].complete(1);
    await first;
    await pumpEventQueue();
    expect(started, hasLength(2));

    // The run now going began before this caller asked, so its result cannot answer them.
    final third = sut.run(body);
    started[1].complete(2);
    expect(await second, 2);
    await pumpEventQueue();

    expect(started, hasLength(3));
    started[2].complete(3);
    expect(await third, 3);
  });

  test('a run that fails still lets the queued one happen', () async {
    final first = sut.run(body);
    final second = sut.run(body);

    started[0].completeError(StateError('the database went away'));
    await expectLater(first, throwsStateError);
    await pumpEventQueue();

    expect(started, hasLength(2), reason: 'a failed run must not wedge the queue');
    started[1].complete(9);
    expect(await second, 9);
  });

  test('a body that throws synchronously does not wedge the runner', () async {
    await expectLater(sut.run(() => throw StateError('nope')), throwsStateError);

    expect(sut.isRunning, isFalse);

    final after = sut.run(body);
    expect(started, hasLength(1), reason: 'the next caller must run, not queue behind a run that never started');
    started[0].complete(4);
    expect(await after, 4);
  });

  test('runs are sequential across generations', () async {
    final first = sut.run(body);
    started[0].complete(1);
    expect(await first, 1);

    final second = sut.run(body);
    expect(started, hasLength(2), reason: 'nothing is outstanding, so this one starts at once');
    started[1].complete(2);
    expect(await second, 2);
  });

  test('a caller arriving between a run finishing and the queued one starting joins the queued run', () async {
    final first = sut.run(body);
    final queued = sut.run(body);

    // The first run's own caller asks again the moment it has its answer, which is before the queued run has started.
    Future<int>? lateCaller;
    unawaited(first.then((_) => lateCaller = sut.run(body)));

    started[0].complete(1);
    await pumpEventQueue();

    expect(started, hasLength(2), reason: 'the late caller must share the queued run, not start a third beside it');
    started[1].complete(2);
    expect(await queued, 2);
    expect(await lateCaller, 2);
  });

  test('the queued run does not run in the zone of the caller that queued it', () async {
    // Stands in for drift's cancellation zone: a value only the queuing caller's fetch should see.
    const key = #serialRunnerTest.caller;
    final seen = <Object?>[];
    Future<int> recordingBody() {
      seen.add(Zone.current[key]);
      return body();
    }

    final first = sut.run(recordingBody);
    final queued = runZoned(() => sut.run(recordingBody), zoneValues: {key: 'cancelled caller'});

    started[0].complete(1);
    await first;
    await pumpEventQueue();

    expect(seen, [null, null], reason: 'a run other callers share must not inherit one caller\'s cancellation');
    started[1].complete(2);
    expect(await queued, 2);
  });
}
