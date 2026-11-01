/// immich-sync fork — providers for the offline mirror.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/domain/services/offline_sync.service.dart';
import 'package:immich_mobile/extensions/network_capability_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/offline.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_download.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:openapi/api.dart';

/// The URL a remote asset's stored copy is named by, for sharing it: its original (the original video, which the store
/// may hold whatever the player now asks for), or its preview.
typedef OfflineStoredUrlOf = Future<String> Function(BaseAsset asset, String remoteId, {required bool preview});

final offlineStoredUrlProvider = Provider<OfflineStoredUrlOf>((ref) {
  final db = ref.watch(driftProvider);
  return (asset, remoteId, {required preview}) async {
    if (!preview && asset.isVideo) {
      return offlineVideoUrl(remoteId, form: 'original');
    }
    // A merged or local asset carries no thumbhash, so it is read from the synced row.
    final carried = asset is RemoteAsset ? asset.thumbHash : null;
    final thumbHash = carried != null && carried.isNotEmpty
        ? carried
        : (await db.remoteAssetRepository.get(remoteId))?.thumbHash ?? '';
    if (preview) {
      return getThumbnailUrlForRemoteId(remoteId, type: AssetMediaSize.preview, thumbhash: thumbHash);
    }
    return offlineOriginalUrl(remoteId, isEdited: asset.isEdited, thumbHash: thumbHash);
  };
});

final offlineRepositoryProvider = Provider<OfflineRepository>((ref) => OfflineRepository(ref.watch(driftProvider)));

final offlineFlagsProvider = Provider<OfflineFlagsRepository>((_) => OfflineFlagsRepository.instance);

// ignore: dispose-provided-instances
final offlineDownloadRepositoryProvider = Provider<OfflineDownloadRepository>((_) => OfflineDownloadRepository());

final offlineSyncServiceProvider = Provider<OfflineSyncService>((ref) {
  final service = OfflineSyncService(
    ref.watch(offlineRepositoryProvider),
    ref.watch(offlineFlagsProvider),
    ref.watch(offlineDownloadRepositoryProvider),
    ref.watch(settingsProvider),
    mayUseNetwork: () async {
      if (!ref.read(settingsProvider).appConfig.offlineWifiOnly) {
        return true;
      }
      try {
        return (await ref.read(connectivityApiProvider).getCapabilities()).hasWifi;
      } catch (_) {
        return true;
      }
    },
  );

  // Downloads run in the foreground only.
  void follow(AppLifecycleState? state) =>
      service.setForeground(state != AppLifecycleState.paused && state != AppLifecycleState.hidden);
  follow(WidgetsBinding.instance.lifecycleState);
  final lifecycle = AppLifecycleListener(onStateChange: follow);
  ref.onDispose(lifecycle.dispose);

  // Older builds downloaded through `background_downloader`; whatever they left queued there is not ours to finish.
  unawaited(OfflineDownloadRepository.cancelLegacyTasks());

  // The mirror gives way to the backup while uploads are actually running: not `remainderCount` or `processingCount`,
  // which stay non-zero for ever over a photo that can never upload. Failed items stay in `uploadItems`, so they are
  // excluded.
  service.bindBackupActivity(() => ref.read(backupProvider).uploadItems.values.any((item) => item.isFailed != true));

  // And picks up again when the backup falls quiet.
  bool isTransferring(BackupState? state) => state?.uploadItems.values.any((item) => item.isFailed != true) ?? false;
  ref.listen(backupProvider, (previous, next) {
    if (isTransferring(previous) && !isTransferring(next)) {
      service.checkSoon();
    }
  });

  // Camera-roll writes, debounced until the writing stops, as the full local sync and hashing write continuously.
  // Removing a local original makes the mirror owe a full copy; hashing decides whether the camera roll holds an item
  // at all.
  Timer? settledLocal;
  final localAssets = ref.watch(offlineRepositoryProvider).watchLocalAssets().listen((_) {
    settledLocal?.cancel();
    settledLocal = Timer(const Duration(seconds: 5), () {
      service.noteLocalAssetsChanged();
      service.checkSoon();
    });
  });

  // Upstream's own tables, the same way.
  Timer? settledRemote;
  final remote = ref.watch(offlineRepositoryProvider).watchRemote().listen((_) {
    // Counted at once: the integrity pass needs to know the table moved during its walk.
    service.noteUpstreamWrite();
    settledRemote?.cancel();
    settledRemote = Timer(const Duration(seconds: 5), () {
      service.noteUpstreamChanged();
      service.checkSoon();
    });
  });

  ref.onDispose(() {
    settledLocal?.cancel();
    settledRemote?.cancel();
    unawaited(localAssets.cancel());
    unawaited(remote.cancel());
  });

  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final offlineStatusProvider = StreamProvider<OfflineStatus>((ref) async* {
  final service = ref.watch(offlineSyncServiceProvider);
  yield service.current;
  yield* service.status;
});

final offlineRevisionProvider = Provider<int>(
  (ref) => ref.watch(offlineStatusProvider.select((status) => status.valueOrNull?.revision ?? 0)),
);

final offlinePolicyProvider = Provider<OfflinePolicy>(
  (ref) => OfflinePolicy.decode(ref.watch(appConfigProvider.select((config) => config.offlinePolicy))),
);

final offlineStorageProvider = FutureProvider.autoDispose<OfflineStorage>((ref) {
  ref.watch(offlineRevisionProvider);
  return ref.watch(offlineSyncServiceProvider).storage();
});

typedef OfflineSpare = ({int bytes, List<String> assetIds});

/// What each album's own change left behind: the bytes and the assets they sit on.
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

  return {for (final entry in bytes.entries) entry.key: (bytes: entry.value, assetIds: assets[entry.key] ?? const [])};
});

/// One album's share of the above, or null while it loads or when there is none.
final offlineAlbumSpareProvider = Provider.autoDispose.family<OfflineSpare?, String>(
  (ref, albumId) => ref.watch(offlineAlbumSparesProvider).valueOrNull?[albumId],
);

final offlineAlbumAssetIdsProvider = FutureProvider.autoDispose.family<List<String>, String>(
  (ref, albumId) async => await ref.watch(offlineRepositoryProvider).assetsInAlbum(albumId),
);

/// Items an album holds above its own rung, what they are held at, and the population that count came from.
typedef OfflineUplift = ({int items, OfflineQuality quality, int total});

/// How much of an album is held above its own rung, and at what. An album only raises quality, so a lower choice is
/// overruled by the library or another album; the row says so.
final offlineAlbumUpliftProvider = FutureProvider.autoDispose.family<OfflineUplift?, String>((ref, albumId) async {
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
  // Counted against the album's storable items, not every link it has.
  return highest == null ? null : (items: items, quality: highest, total: ids.length);
});

/// How many of each album's items an excluded album takes away, for every album in one query.
final offlineExcludedOverlapProvider = FutureProvider.autoDispose<Map<String, int>>((ref) {
  final excluded = ref.watch(offlinePolicyProvider).excluded;
  if (excluded.isEmpty) {
    return Future.value(const {});
  }
  return ref.watch(offlineRepositoryProvider).excludedOverlapCounts(excluded);
});

/// One album's share of the above. Zero for an excluded album, and for one on the global settings while those keep
/// nothing.
final offlineAlbumExcludedProvider = Provider.autoDispose.family<int, String>((ref, albumId) {
  final policy = ref.watch(offlinePolicyProvider);
  final wouldKeep = switch (policy.stateOf(albumId)) {
    OfflineAlbumState.excluded => false,
    OfflineAlbumState.included => true,
    OfflineAlbumState.notIncluded => policy.library != null,
  };
  if (!wouldKeep) {
    return 0;
  }
  return ref.watch(offlineExcludedOverlapProvider).valueOrNull?[albumId] ?? 0;
});

final offlineAlbumCountsProvider = FutureProvider<Map<String, int>>(
  (ref) => ref.watch(offlineRepositoryProvider).albumAssetCounts(),
);
