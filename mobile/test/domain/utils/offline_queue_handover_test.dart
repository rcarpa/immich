/// immich-sync fork — how much the queue hands the downloader at once (FORK.md §3.3): a deep window of small files, so
/// every slot stays busy, and a shallow one of full-size files, so they do not hold up what is handed over after them.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/utils/offline_queue.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_download.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:mocktail/mocktail.dart';

class _MockDownloads extends Mock implements OfflineDownloadRepository {}

class _MockSettings extends Mock implements SettingsRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _MockDownloads downloads;
  late OfflineDownloadQueue queue;
  late List<OfflineDownload> enqueued;

  setUpAll(() => registerFallbackValue(<OfflineDownload>[]));

  setUp(() {
    // An empty store, so nothing is claimed off disk and everything is handed over.
    root = Directory.systemTemp.createTempSync('offline_queue');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );

    enqueued = [];
    downloads = _MockDownloads();
    when(() => downloads.enqueue(any(), wifiOnly: any(named: 'wifiOnly'))).thenAnswer((call) async {
      enqueued.addAll(call.positionalArguments.first as List<OfflineDownload>);
      return const [];
    });
    final settings = _MockSettings();
    when(() => settings.appConfig).thenReturn(const AppConfig());

    queue = OfflineDownloadQueue(
      downloads,
      settings,
      onHeld: (_) {},
      onChanged: () {},
      onRefused: (_) {},
      hasRoom: () => true,
      isBackingUp: () => false,
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  List<OfflineMissingFile> files(OfflineVariant variant, int count, {int from = 0, int touchedAt = 100}) => [
    for (var i = from; i < from + count; i++)
      OfflineMissingFile(
        'asset-$i',
        OfflineFile('https://photos.example.com/api/assets/asset-$i/${variant.name}', variant),
        touchedAt: touchedAt,
        createdAt: 1000 - i,
      ),
  ];

  test('keeps a deep window of small files with the downloader', () async {
    queue.replace(files(OfflineVariant.thumbnail, 300));

    await queue.topUp();

    expect(enqueued, hasLength(200));
    expect(queue.queued, 200);
    expect(queue.pending, 100);
  });

  test('holds few full-size files at once, and hands over the next as one finishes', () async {
    queue.replace(files(OfflineVariant.original, 40));

    await queue.topUp();
    expect(enqueued, hasLength(16));

    queue.noteFinished(fullSize: true);
    await queue.topUp();
    expect(enqueued, hasLength(17));
  });

  test('a full-size file at the head waits for a slot rather than being skipped', () async {
    // A newer decision's original ahead of an older decision's thumbnails, which is the order the queue keeps.
    queue
      ..resetOutstanding(16, fullSize: 16)
      ..replace([
        ...files(OfflineVariant.original, 1, touchedAt: 200),
        ...files(OfflineVariant.thumbnail, 5, from: 1),
      ]);

    await queue.topUp();

    // Nothing jumps ahead of it, and nothing is handed over until a full-size slot frees up.
    expect(enqueued, isEmpty);
    queue.noteFinished(fullSize: true);
    await queue.topUp();
    expect(enqueued.first.file.variant, OfflineVariant.original);
    expect(enqueued, hasLength(6));
  });
}
