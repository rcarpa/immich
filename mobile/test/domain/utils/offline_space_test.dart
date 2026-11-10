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

  group('what eviction takes', () {
    const mb = 1024 * 1024;

    test('nothing while the store is under its target', () {
      expect(space.evictionNeed(held: _gb ~/ 2, spare: _gb ~/ 2, limit: _gb), 0);
    });

    test("against the user's limit, the reserve of spares stays", () {
      // A library alone over the limit: the few spares from browsing are left alone.
      expect(space.evictionNeed(held: 2 * _gb, spare: 100 * mb, limit: _gb), 0);
      expect(space.evictionNeed(held: 2 * _gb, spare: offlineSpareReserve, limit: _gb), 0);
    });

    test('spares that outgrow the reserve go down to a fifth under it', () {
      const spare = offlineSpareReserve + 10 * mb;
      expect(
        space.evictionNeed(held: 2 * _gb, spare: spare, limit: _gb),
        spare - offlineSpareReserve * 4 ~/ 5,
      );
    });

    test('never more than brings the store back to its target', () {
      final target = space.evictionTarget(10 * _gb)!;
      expect(space.evictionNeed(held: target + mb, spare: 5 * _gb, limit: 10 * _gb), mb);
    });

    test('a phone running out of room takes the reserve too', () {
      space.measure(held: 2 * _gb, free: _gb ~/ 2);
      final target = space.evictionTarget(0)!;
      expect(space.evictionNeed(held: 2 * _gb, spare: 100 * mb, limit: 0), 2 * _gb - target);
      expect(space.evictionNeed(held: 2 * _gb, spare: 100 * mb, limit: 50 * _gb), 2 * _gb - target);
    });
  });
}
