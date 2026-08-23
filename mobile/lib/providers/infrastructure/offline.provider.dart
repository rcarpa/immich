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
import 'package:immich_mobile/providers/backup/backup.provider.dart';
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
  service.bindBackupActivity(() => ref.read(backupProvider).uploadItems.values.any((item) => item.isFailed != true));

  // And picks up again when the backup falls quiet. In practice a finished upload is itself a remote change, which
  // already wakes the mirror — but not when the last upload failed, and a mirror that waits for an unrelated event is a
  // mirror that looks broken.
  bool isTransferring(BackupState? state) => state?.uploadItems.values.any((item) => item.isFailed != true) ?? false;
  ref.listen(backupProvider, (previous, next) {
    if (isTransferring(previous) && !isTransferring(next)) {
      service.checkSoon();
    }
  });

  // A camera-roll change is the one input nothing else reports. `onRemoteChanged` watches the server; this watches the
  // device, so deleting a local original — by *remove from device*, by Free Up Space, or in Photos — makes the mirror
  // notice that it now owes those photos a full copy, instead of leaving it until the next cold start.
  //
  // Held until the writing stops, rather than passed straight on. The two things that write this table in bulk — the
  // full local sync at launch and a hashing run — write it continuously for as long as they last, and every one of
  // those writes is an event here. Restarting the timer collapses a whole run into one pass at the end of it, which is
  // when there is something new to say anyway; without it the mirror asks questions of a table upstream is still
  // filling, over the connection the timeline is waiting on for its own first read.
  //
  // The pass is *told* about it as well as asked to run, and that is the load-bearing half: `check` gates on a
  // fingerprint of upstream, and the fingerprint counts camera-roll rows. Hashing writes a checksum onto a row that was
  // already there, which moves no count and is exactly the write that decides whether the mirror owes the item a
  // full-size copy — so without the flag the pass this wakes concludes nothing has changed and goes back to sleep.
  Timer? settledLocal;
  final localAssets = ref.watch(offlineRepositoryProvider).watchLocalAssets().listen((_) {
    settledLocal?.cancel();
    settledLocal = Timer(const Duration(seconds: 5), () {
      service.noteLocalAssetsChanged();
      service.checkSoon();
    });
  });

  // And the server side, for the same reason and by the same means. `onRemoteChanged` already asks for a pass on every
  // path that applies server state, but it cannot cover a write the app makes itself — applying an edit, for one — and
  // a pass that is asked for but then decides nothing has changed is the same as no pass at all.
  Timer? settledRemote;
  final remote = ref.watch(offlineRepositoryProvider).watchRemote().listen((_) {
    // Counted at once, though the pass waits for the writing to stop: the integrity pass needs to know that the table
    // moved during its walk, and a note five seconds late arrives after it has already decided (`_upstreamWrites`).
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

  return {for (final entry in bytes.entries) entry.key: (bytes: entry.value, assetIds: assets[entry.key] ?? const [])};
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

/// Items an album holds above its own rung, what they are held at, and the population that count came from.
typedef OfflineUplift = ({int items, OfflineQuality quality, int total});

/// How much of an album is held above the rung the album itself asks for, and at what.
///
/// An album's own setting raises quality and never lowers it — what an item is kept at is the most generous of the
/// library setting and every album naming it (FORK.md §3.2) — so a lower choice is recorded and then overruled. The row
/// says so rather than appearing to do nothing, and says it exactly: the count comes from resolving each of the album's
/// items against the whole policy, which is also what decides them.
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
  // The population the count came from, which is the album's *storable* items. The row's own total counts every link
  // the album has, trashed items included, so comparing against that made "all of them" a phrase the line could
  // almost never use.
  return highest == null ? null : (items: items, quality: highest, total: ids.length);
});

/// How many of each album's items an *excluded* album takes away, for every album at once.
///
/// One query rather than one per row: the screen lists every album the server has, and the answer is a single grouped
/// count. Recomputed when the exclusions change, which is the only thing that alters it short of album membership
/// moving — and being auto-disposed, it is asked again each time a screen showing albums is opened.
final offlineExcludedOverlapProvider = FutureProvider.autoDispose<Map<String, int>>((ref) {
  final excluded = ref.watch(offlinePolicyProvider).excluded;
  if (excluded.isEmpty) {
    return Future.value(const {});
  }
  return ref.watch(offlineRepositoryProvider).excludedOverlapCounts(excluded);
});

/// One album's share of the above, and zero wherever reporting it would mislead.
///
/// Only an album that *would otherwise be keeping* those items loses anything to the exclusion. An album that is
/// itself excluded loses nothing by definition, and one left on the global settings loses nothing while those keep
/// nothing — there, some third album is the thing being overruled, and its own row says so.
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

/// Number of assets in each album, for the selection screen.
final offlineAlbumCountsProvider = FutureProvider<Map<String, int>>(
  (ref) => ref.watch(offlineRepositoryProvider).albumAssetCounts(),
);
