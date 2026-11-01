/// immich-sync fork: how much the store may hold. One storage limit, plus [offlineFreeSpaceFloor] always left free on
/// the device; over it, eviction takes spares down to a little under the ceiling.
library;

import 'dart:math' as math;

/// Space always left free on the device, whatever the limit. Spares are evicted to keep it.
const offlineFreeSpaceFloor = 1024 * 1024 * 1024;

/// How far under the ceiling eviction goes at most, so a full store does not evict on every new file.
const offlineEvictionSlack = 256 * 1024 * 1024;

class OfflineSpace {
  /// What the device can give the store: what it holds plus free space, minus the floor. Null where unknown.
  int? _device;

  /// Free space moves with everything else on the phone, so it is read again before each pass and eviction.
  void measure({required int held, required int? free}) =>
      _device = free == null ? null : math.max(0, held + free - offlineFreeSpaceFloor);

  /// The most the store may hold: the user's [limit] (zero for none), capped by the device. Null for no ceiling.
  int? ceiling(int limit) {
    final device = _device;
    if (limit <= 0) {
      return device;
    }
    return device == null ? limit : math.min(limit, device);
  }

  /// Whether a store of [held] bytes may still grow.
  bool hasRoom({required int held, required int limit}) {
    final ceiling = this.ceiling(limit);
    return ceiling == null || held < ceiling;
  }

  /// What eviction brings the store down to: a twentieth under the ceiling, at most [offlineEvictionSlack]. Null for no
  /// ceiling.
  int? evictionTarget(int limit) {
    final ceiling = this.ceiling(limit);
    return ceiling == null ? null : ceiling - math.min(ceiling ~/ 20, offlineEvictionSlack);
  }
}
