import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';
import 'package:immich_mobile/providers/session_state.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';

final backgroundSyncProvider = Provider<BackgroundSyncManager>((ref) {
  final syncStatusNotifier = ref.read(syncStatusProvider.notifier);
  // immich-sync fork: upstream resets seen when the running remote sync started.
  Future<int?>? resetGeneration;

  final manager = BackgroundSyncManager(
    onRemoteSyncStart: () {
      syncStatusNotifier.startRemoteSync();
      // immich-sync fork
      resetGeneration = _readResetGeneration();
      // ignore: dispose-provided-instances
      final backupNotifier = ref.read(backupProvider.notifier);
      if (backupNotifier.mounted) {
        backupNotifier.updateError(BackupError.none);
      }
    },
    onRemoteSyncComplete: (isSuccess) {
      syncStatusNotifier.completeRemoteSync();
      // ignore: dispose-provided-instances
      final backupNotifier = ref.read(backupProvider.notifier);
      if (backupNotifier.mounted) {
        backupNotifier.updateError(isSuccess == true ? BackupError.none : BackupError.syncFailed);
      }
      // immich-sync fork
      _afterRemoteSync(ref, synced: isSuccess == true, resetGeneration: resetGeneration);
    },
    onRemoteSyncError: (error) {
      syncStatusNotifier.errorRemoteSync(error);
      // immich-sync fork
      _afterRemoteSync(ref, synced: false, resetGeneration: resetGeneration);
    },
    onLocalSyncStart: syncStatusNotifier.startLocalSync,
    onLocalSyncComplete: syncStatusNotifier.completeLocalSync,
    onLocalSyncError: syncStatusNotifier.errorLocalSync,
    onHashingStart: syncStatusNotifier.startHashJob,
    onHashingComplete: syncStatusNotifier.completeHashJob,
    onHashingError: syncStatusNotifier.errorHashJob,
    onCloudIdSyncStart: syncStatusNotifier.startCloudIdSync,
    onCloudIdSyncComplete: syncStatusNotifier.completeCloudIdSync,
    onCloudIdSyncError: syncStatusNotifier.errorCloudIdSync,
  );
  ref.onDispose(manager.cancel);
  return manager;
});

/// immich-sync fork: a failed remote sync is how the app learns the server is unreachable (R2), and a finished one is
/// when the offline mirror catches up with what it brought in. A sync also fails on errors of its own, inside the
/// isolate, so a failure counts as unreachable only when the server does not answer a ping either.
void _afterRemoteSync(Ref ref, {required bool synced, required Future<int?>? resetGeneration}) {
  unawaited(() async {
    final reachedServer = synced || await _serverAnswers(ref);
    final sessionIssue = ref.read(sessionIssueProvider.notifier);
    if (synced) {
      sessionIssue.clear();
    } else if (reachedServer) {
      sessionIssue.reportReachable();
    } else {
      await sessionIssue.reportUnreachable();
    }
    ref
        .read(offlineSyncServiceProvider)
        .afterRemoteSync(synced: synced, reachedServer: reachedServer, resetGeneration: await resetGeneration);
  }());
}

/// Read straight from the repository, so the start of a sync does not build the mirror's service. Null if it cannot be
/// read, which leaves marking upstream complete to the next sync.
Future<int?> _readResetGeneration() async {
  try {
    return await OfflineFlagsRepository.instance.resetGeneration();
  } catch (_) {
    return null;
  }
}

Future<bool> _serverAnswers(Ref ref) async {
  try {
    await ref.read(apiServiceProvider).serverInfoApi.pingServer().timeout(const Duration(seconds: 5));
    return true;
  } catch (_) {
    return false;
  }
}
