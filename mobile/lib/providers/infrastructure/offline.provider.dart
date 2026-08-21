/// immich-sync fork — providers for the offline mirror.
library;

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/domain/services/offline_sync.service.dart';
import 'package:immich_mobile/infrastructure/repositories/offline.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_download.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';

final offlineRepositoryProvider = Provider<OfflineRepository>((ref) => OfflineRepository(ref.watch(driftProvider)));

/// The fork's own database, opened during bootstrap.
final offlineFlagsProvider = Provider<OfflineFlagsRepository>((_) => OfflineFlagsRepository.instance);

// ignore: dispose-provided-instances
final offlineDownloadRepositoryProvider = Provider<OfflineDownloadRepository>((_) => OfflineDownloadRepository());

final offlineSyncServiceProvider = Provider<OfflineSyncService>((ref) {
  final service = OfflineSyncService(
    ref.watch(offlineRepositoryProvider),
    ref.watch(offlineFlagsProvider),
    ref.watch(offlineDownloadRepositoryProvider),
    ref.watch(settingsProvider),
  );

  // The mirror gives way to the backup: read rather than watched, so asking the question never rebuilds this provider,
  // and asked at hand-over time so the answer is current.
  //
  // Tasks in flight that have not failed, which is the only count here that means "bytes are moving". The two that look
  // like it are not: `remainderCount` is the backlog — "assets that do not yet exist on the server" — and
  // `processingCount` is assets still waiting to be hashed (`backup.repository.dart`). Both stay non-zero for ever over
  // a photo the backup can never send, and iOS supplies them: a camera-roll original whose temporary copy has gone
  // fails with `PathNotFoundException` on every retry. Yielding to that is a deadlock, not a courtesy — the mirror stops
  // downloading for the life of the install, with nothing on any screen saying why. A failed item stays in
  // `uploadItems`, since that is what draws the error list, so it is excluded here by name.
  service.bindBackupActivity(
    () => ref.read(driftBackupProvider).uploadItems.values.any((item) => item.isFailed != true),
  );

  // And picks up again when the backup falls quiet. In practice a finished upload is itself a remote change, which
  // already wakes the mirror — but not when the last upload failed, and a mirror that waits for an unrelated event is a
  // mirror that looks broken.
  bool isTransferring(DriftBackupState? state) =>
      state?.uploadItems.values.any((item) => item.isFailed != true) ?? false;
  ref.listen(driftBackupProvider, (previous, next) {
    if (isTransferring(previous) && !isTransferring(next)) {
      service.checkSoon();
    }
  });

  // A camera-roll change is the one input nothing else reports. `onRemoteChanged` watches the server; this watches the
  // device, so deleting a local original — by *remove from device*, by Free Up Space, or in Photos — makes the mirror
  // notice that it now owes those photos a full copy, instead of leaving it until the next cold start.
  final localAssets = ref.watch(offlineRepositoryProvider).watchLocalAssetCount().listen((_) => service.checkSoon());
  ref.onDispose(() => unawaited(localAssets.cancel()));

  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// Live mirror status, seeded with the current value so a screen opened mid-pass shows real numbers rather than zeros.
final offlineStatusProvider = StreamProvider<OfflineStatus>((ref) async* {
  final service = ref.watch(offlineSyncServiceProvider);
  yield service.current;
  yield* service.status;
});

/// Bumped when what is stored may have changed.
final offlineRevisionProvider = Provider<int>(
  (ref) => ref.watch(offlineStatusProvider.select((status) => status.valueOrNull?.revision ?? 0)),
);

/// What happens to photos that arrive later.
final offlinePolicyProvider = Provider<OfflinePolicy>(
  (ref) => OfflinePolicy.decode(ref.watch(appConfigProvider.select((config) => config.offlinePolicy))),
);

/// How the store's bytes are being used.
final offlineStorageProvider = FutureProvider.autoDispose<OfflineStorage>((ref) {
  ref.watch(offlineRevisionProvider);
  return ref.watch(offlineSyncServiceProvider).storage();
});

typedef OfflineSpare = ({int bytes, List<String> assetIds});

/// What each album's own change left behind: the bytes, and the assets they sit on, which is what the offer to remove
/// them has to be scoped to.
final offlineAlbumSparesProvider = FutureProvider.autoDispose<Map<String, OfflineSpare>>((ref) async {
  ref.watch(offlineRevisionProvider);
  final spares = await ref.watch(offlineSyncServiceProvider).spareBytesByAsset();
  if (spares.isEmpty) {
    return const {};
  }

  final albums = await ref.watch(offlineRepositoryProvider).albumsOf(spares.keys.toList());
  final bytes = <String, int>{};
  final assets = <String, List<String>>{};
  albums.forEach((assetId, albumIds) {
    final size = spares[assetId];
    if (size == null) {
      return;
    }
    for (final albumId in albumIds) {
      bytes[albumId] = (bytes[albumId] ?? 0) + size;
      (assets[albumId] ??= []).add(assetId);
    }
  });

  return {
    for (final entry in bytes.entries) entry.key: (bytes: entry.value, assetIds: assets[entry.key] ?? const []),
  };
});

/// One album's share of the above, or null while it loads or when there is none.
final offlineAlbumSpareProvider = Provider.autoDispose.family<OfflineSpare?, String>(
  (ref, albumId) => ref.watch(offlineAlbumSparesProvider).valueOrNull?[albumId],
);

/// Asset ids in one album, for its own offline row.
final offlineAlbumAssetIdsProvider = FutureProvider.autoDispose.family<List<String>, String>(
  (ref, albumId) async =>
      (await ref.watch(offlineRepositoryProvider).assetsInAlbum(albumId)).map((asset) => asset.id).toList(),
);

/// How much of an album is held above the rung the album itself asks for, and at what.
///
/// An album's own setting raises quality and never lowers it — what an item is kept at is the most generous of the
/// library setting and every album naming it (FORK.md §3.2) — so a lower choice is recorded and then overruled. The row
/// says so rather than appearing to do nothing, and says it exactly: the count comes from resolving each of the album's
/// items against the whole policy, which is also what decides them.
final offlineAlbumUpliftProvider = FutureProvider.autoDispose.family<({int items, OfflineQuality quality})?, String>((
  ref,
  albumId,
) async {
  final policy = ref.watch(offlinePolicyProvider);
  final own = policy.albums[albumId];
  if (own == null) {
    return null;
  }

  final ids = await ref.watch(offlineAlbumAssetIdsProvider(albumId).future);
  final albums = await ref.watch(offlineRepositoryProvider).albumsOf(ids);

  var items = 0;
  OfflineQuality? highest;
  for (final id in ids) {
    final effective = policy.resolve(albums[id] ?? const []);
    if (effective == null || effective.code <= own.code) {
      continue;
    }
    items++;
    highest = highest == null ? effective : highest.atLeast(effective);
  }
  return highest == null ? null : (items: items, quality: highest);
});

/// Number of assets in each album, for the selection screen.
final offlineAlbumCountsProvider = FutureProvider<Map<String, int>>(
  (ref) => ref.watch(offlineRepositoryProvider).albumAssetCounts(),
);
