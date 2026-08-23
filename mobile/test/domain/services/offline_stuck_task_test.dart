/// immich-sync fork — when the mirror gives up on a download (FORK.md §3.7): a task that started and went quiet, or one
/// that never started while the whole group has been quiet too. Never one merely waiting its turn behind busy slots.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/offline_sync.service.dart';

void main() {
  final now = DateTime(2026, 10, 30, 12);
  DateTime ago(int minutes) => now.subtract(Duration(minutes: minutes));

  group('a task that has started', () {
    test('is dead once it has said nothing for fifteen minutes', () {
      expect(offlineTaskIsDead(now: now, lastSign: ago(15), groupMoved: ago(0), watchingSince: ago(60)), isTrue);
    });

    test('is alive while it reports, however long it has been held', () {
      expect(offlineTaskIsDead(now: now, lastSign: ago(14), groupMoved: ago(0), watchingSince: ago(600)), isFalse);
    });
  });

  group('a task that has not started', () {
    test('is waiting its turn, not dead, while other tasks are moving', () {
      // Behind eight slow videos: held for hours, but the group reported a moment ago.
      expect(offlineTaskIsDead(now: now, lastSign: null, groupMoved: ago(1), watchingSince: ago(240)), isFalse);
    });

    test('is dead once the whole group has been silent for fifteen minutes', () {
      expect(offlineTaskIsDead(now: now, lastSign: null, groupMoved: ago(15), watchingSince: ago(15)), isTrue);
    });

    test('is dead when nothing has moved since launch, after the settling grace', () {
      expect(offlineTaskIsDead(now: now, lastSign: null, groupMoved: null, watchingSince: ago(2)), isTrue);
    });

    test('gets the settling grace after a launch before it is called dead', () {
      // An old task with nothing to show for it yet, because this process has only just started listening.
      expect(offlineTaskIsDead(now: now, lastSign: null, groupMoved: null, watchingSince: ago(1)), isFalse);
    });
  });
}
