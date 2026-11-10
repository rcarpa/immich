import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/platform/background_worker_api.g.dart';
import 'package:immich_mobile/platform/background_worker_lock_api.g.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/platform/network_api.g.dart';
import 'package:immich_mobile/platform/passkey_api.g.dart';
import 'package:immich_mobile/platform/permission_api.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';

final backgroundWorkerFgServiceProvider = Provider((_) => BackgroundWorkerFgService(BackgroundWorkerFgHostApi()));

final backgroundWorkerLockServiceProvider = Provider<BackgroundWorkerLockService>(
  (_) => BackgroundWorkerLockService(BackgroundWorkerLockApi()),
);

final nativeSyncApiProvider = Provider<NativeSyncApi>((_) => NativeSyncApi());

final permissionApiProvider = Provider<PermissionApi>((_) => PermissionApi());

final connectivityApiProvider = Provider<ConnectivityApi>((_) => ConnectivityApi());

// immich-sync fork: the server takes passkeys only from apps Immich signs (its Android certificates and its Apple
// team for my.immich.app), so this build reports none and the login button and settings section stay hidden.
final passkeyHostApiProvider = Provider<PasskeyHostApi>((_) => _NoPasskeyHostApi());

class _NoPasskeyHostApi extends PasskeyHostApi {
  @override
  Future<bool> isSupported() async => false;
}

final localImageApi = LocalImageApi();

final remoteImageApi = RemoteImageApi();

final networkApi = NetworkApi();
