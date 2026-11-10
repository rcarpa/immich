import 'package:pigeon/pigeon.dart';

class OfflineStoredFile {
  final String name;
  final int size;

  const OfflineStoredFile({required this.name, required this.size});
}

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/offline_store_api.g.dart',
    swiftOut: 'ios/Runner/Images/OfflineStoreApi.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/images/OfflineStoreApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.images', includeErrorClass: false),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
@HostApi()
abstract class OfflineStoreApi {
  /// Asks for [OfflineStoreListener] reports. Only the app's own engine is accepted.
  bool listen();

  void noteStored(List<String> names);

  void noteRemoved(List<String> names);

  void forgetAll();

  int? freeSpace();

  /// Returns the size of the file. Fails with the code `http` (status in details), `network`, `integrity` or
  /// `cancelled`.
  @async
  int download(
    String id,
    String url,
    String path, {
    required bool heavy,
    String? checksum,
    required bool wifiOnly,
  });

  void cancelDownload(String id);

  void cancelAll();

  /// Whether the process is kept running while the app is in the background.
  bool keepAlive(int pending, bool wifiOnly);
}

@FlutterApi()
abstract class OfflineStoreListener {
  /// What the image path stored and served since the last report.
  void onActivity(List<OfflineStoredFile> stored, List<String> read);
}
