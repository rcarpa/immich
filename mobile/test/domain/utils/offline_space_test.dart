/// immich-sync fork: one storage limit, plus a floor always left free on the device.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/utils/offline_space.dart';

const _gb = 1024 * 1024 * 1024;

void main() {
  late OfflineSpace space;

  setUp(() => space = OfflineSpace());

  test('no limit and no reading means no ceiling', () {
    expect(space.ceiling(0), isNull);
    expect(space.hasRoom(held: 100 * _gb, limit: 0), isTrue);
    expect(space.evictionTarget(0), isNull);
  });

  test('the device gives what the store holds plus free space, less the floor', () {
    space.measure(held: 10 * _gb, free: 3 * _gb);

    expect(space.ceiling(0), 12 * _gb);
    expect(space.hasRoom(held: 10 * _gb, limit: 0), isTrue);
    expect(space.hasRoom(held: 12 * _gb, limit: 0), isFalse);
  });

  test('a nearly full phone gives nothing, never less', () {
    space.measure(held: 0, free: _gb ~/ 2);

    expect(space.ceiling(0), 0);
  });

  test("the user's limit applies, capped by the device", () {
    space.measure(held: 10 * _gb, free: 100 * _gb);
    expect(space.ceiling(20 * _gb), 20 * _gb);

    space.measure(held: 10 * _gb, free: 2 * _gb);
    expect(space.ceiling(20 * _gb), 11 * _gb);
  });

  test('eviction goes a twentieth under the ceiling, at most the slack', () {
    expect(space.evictionTarget(_gb), _gb - _gb ~/ 20);
    expect(space.evictionTarget(100 * _gb), 100 * _gb - offlineEvictionSlack);
  });
}
