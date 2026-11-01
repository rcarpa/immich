/// immich-sync fork: how the queue downloads: small files under an adaptive limit, a few full-size ones, and what
/// happens when the app leaves the screen.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/utils/offline_queue.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_download.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:mocktail/mocktail.dart';

class _MockSettings extends Mock implements SettingsRepository {}

/// Downloads that finish only when the test says so.
class _FakeDownloads extends OfflineDownloadRepository {
  final calls = <String, Completer<int>>{};
  final lanes = <String, OfflineLane>{};
  final checksums = <String, String?>{};
  var keptAlive = false;
  var cancelledAll = 0;
  Object? throwOnFetch;

  @override
  Future<int> fetch(
    String url,
    String path, {
    OfflineLane lane = OfflineLane.light,
    String? checksum,
    bool wifiOnly = false,
    Future<void>? abort,
  }) {
    final error = throwOnFetch;
    if (error != null) {
      return Future.error(error);
    }
    final completer = Completer<int>();
    calls[url] = completer;
    lanes[url] = lane;
    checksums[url] = checksum;
    unawaited(
      abort?.then((_) {
        if (!completer.isCompleted) {
          completer.completeError(const OfflineDownloadCancelled());
        }
      }),
    );
    return completer.future;
  }

  @override
  Future<bool> keepAlive({required int pending, required bool wifiOnly}) async => keptAlive && pending > 0;

  @override
  Future<void> cancelAll() async => cancelledAll++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _FakeDownloads downloads;
  late OfflineDownloadQueue queue;
  late List<OfflineHeldRow> held;
  late List<OfflineMissingFile> failed;
  late bool networkAllowed;
  late int letGo;
  late List<List<String>> lookups;

  setUp(() {
    // An empty store, so nothing is claimed off disk.
    root = Directory.systemTemp.createTempSync('offline_queue');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );

    downloads = _FakeDownloads();
    held = [];
    failed = [];
    networkAllowed = true;
    letGo = 0;
    lookups = [];
    final settings = _MockSettings();
    when(() => settings.appConfig).thenReturn(const AppConfig());

    queue = OfflineDownloadQueue(
      downloads,
      settings,
      onHeld: held.add,
      onDownloaded: (_) {},
      onFailed: (entry, _) => failed.add(entry),
      onLetGo: () => letGo++,
      onChanged: () {},
      onDrained: () {},
      hasRoom: () => true,
      isBackingUp: () => false,
      mayUseNetwork: () async => networkAllowed,
      // On this isolate, so [settle] covers it.
      lookOnDisk: (root, names) async {
        lookups.add(names);
        return {for (final name in names) name: ?offlineAdopt(root, name)};
      },
    );
  });

  tearDown(() {
    queue.dispose();
    root.deleteSync(recursive: true);
  });

  List<OfflineMissingFile> files(
    OfflineVariant variant,
    int count, {
    int from = 0,
    int touchedAt = 100,
    String? checksum,
  }) => [
    for (var i = from; i < from + count; i++)
      OfflineMissingFile(
        'asset-$i',
        OfflineFile('https://photos.example.com/api/assets/asset-$i/${variant.name}', variant, checksum: checksum),
        touchedAt: touchedAt,
        createdAt: 1000 - i,
      ),
  ];

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('runs a few small files at once and starts the next as one lands', () async {
    queue.replace(files(OfflineVariant.thumbnail, 40));

    await queue.topUp();
    expect(queue.queued, 6);
    expect(queue.pending, 34);
    expect(downloads.lanes.values.toSet(), {OfflineLane.light});

    downloads.calls.values.first.complete(10);
    await settle();

    expect(held, hasLength(1));
    expect(queue.queued, 6);
    expect(queue.pending, 33);
  });

  test('quick successes widen the small-file lane; a network failure narrows it', () async {
    queue.replace(files(OfflineVariant.thumbnail, 60));
    await queue.topUp();

    // A full round of quick successes earns one more slot.
    for (var i = 0; i < 6; i++) {
      downloads.calls.values.firstWhere((call) => !call.isCompleted).complete(10);
      await settle();
    }
    expect(queue.lightLimit, 7);
    expect(queue.queued, 7);

    downloads.calls.values.firstWhere((call) => !call.isCompleted).completeError(const OfflineDownloadException('timeout'));
    await settle();
    expect(queue.lightLimit, 3);
  });

  test('a full-size file goes to the heavy lane with its checksum', () async {
    queue.replace(files(OfflineVariant.original, 1, checksum: 'c2hhMQ=='));

    await queue.topUp();

    final url = downloads.calls.keys.single;
    expect(downloads.lanes[url], OfflineLane.heavy);
    expect(downloads.checksums[url], 'c2hhMQ==');
  });

  test('a full lane does not hold the other one up, and each keeps its order', () async {
    queue.replace([
      ...files(OfflineVariant.original, 4, touchedAt: 200),
      ...files(OfflineVariant.thumbnail, 8, from: 4),
    ]);

    await queue.topUp();

    // Three originals and six thumbnails run; the fourth original and the last two thumbnails wait their turn.
    expect(downloads.lanes.values.where((lane) => lane == OfflineLane.heavy), hasLength(3));
    expect(downloads.lanes.values.where((lane) => lane == OfflineLane.light), hasLength(6));
    expect(downloads.calls.keys, isNot(contains(endsWith('asset-3/original'))));
    expect(downloads.calls.keys, isNot(contains(endsWith('asset-10/thumbnail'))));
    expect(queue.pending, 3);
  });

  test('going to the background aborts small files and keeps them at the front of the queue', () async {
    queue.replace(files(OfflineVariant.thumbnail, 40));
    await queue.topUp();

    queue.setSuspended(true);
    await settle();

    expect(queue.queued, 0);
    expect(queue.pending, 40);
    expect(queue.stoppedBecause, 'the app is in the background');
    expect(held, isEmpty);
    expect(failed, isEmpty);

    queue.setSuspended(false);
    await settle();
    expect(queue.queued, 6);
  });

  test('going to the background leaves full-size files running and hands over a batch more', () async {
    queue.replace([
      ...files(OfflineVariant.original, 2, touchedAt: 300),
      ...files(OfflineVariant.thumbnail, 3, from: 2, touchedAt: 200),
      ...files(OfflineVariant.video, 20, from: 5),
    ]);
    await queue.topUp();
    expect(queue.queued, 6);

    queue.setSuspended(true);
    await settle();

    // The two originals keep going; eight videos join them, up to ten; the thumbnails wait in front.
    expect(queue.queued, 10);
    expect(queue.inFlight.every((name) => !name.contains('thumbnail')), isTrue);
    expect(queue.pending, 3 + 12);
    expect(queue.entries.skip(10).take(3).every((entry) => entry.file.variant == OfflineVariant.thumbnail), isTrue);

    // One finishing while away is replaced by the next.
    downloads.calls.values.firstWhere((call) => !call.isCompleted).complete(10);
    await settle();
    expect(queue.queued, 10);
    expect(queue.pending, 3 + 11);
  });

  test('handing over looks for the full-size files on disk in one batch', () async {
    final originals = files(OfflineVariant.original, 3);
    // The store root is cached across tests, so the file goes when this one ends.
    final stored = File(offlinePinnedPath(await offlineStoreRoot(), originals.first.file.name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(7, 1));
    addTearDown(stored.deleteSync);
    queue.replace([...files(OfflineVariant.thumbnail, 2, from: 3, touchedAt: 200), ...originals]);

    queue.setSuspended(true);
    await settle();

    expect(lookups, [
      [for (final entry in originals) entry.file.name],
    ]);
    expect(held.single.size, 7);
    expect(queue.queued, 2);
    expect(queue.pending, 2);
  });

  test('kept running in the background, the queue carries on as in the foreground', () async {
    downloads.keptAlive = true;
    queue.replace(files(OfflineVariant.thumbnail, 40));
    await queue.topUp();

    queue.setSuspended(true);
    await settle();

    expect(queue.queued, 6);
    expect(queue.stoppedBecause, isNull);

    downloads.calls.values.first.complete(10);
    await settle();
    expect(held, hasLength(1));
    expect(queue.queued, 6);
  });

  test('clearing also cancels downloads nobody waits for any more', () async {
    queue.replace(files(OfflineVariant.original, 2));
    await queue.topUp();

    queue.clear();
    await settle();

    expect(queue.isIdle, isTrue);
    expect(downloads.cancelledAll, 1);
  });

  test('a file the server refuses is reported; network failures only hold the queue off once they persist', () async {
    queue.replace(files(OfflineVariant.thumbnail, 10));
    await queue.topUp();
    final calls = downloads.calls.values.toList();

    calls[0].completeError(const OfflineDownloadException('HTTP 404', statusCode: 404));
    await settle();
    expect(failed, hasLength(1));
    expect(queue.stoppedBecause, isNull);

    // One network failure among running downloads does not stop the queue; three in a row do.
    calls[1].completeError(const OfflineDownloadException('timeout'));
    await settle();
    expect(failed, hasLength(1));
    expect(queue.stoppedBecause, isNull);

    calls[2].completeError(const OfflineDownloadException('offline'));
    calls[3].completeError(const OfflineDownloadException('offline'));
    await settle();
    expect(queue.stoppedBecause, 'waiting for the server to be reachable');
  });

  test('a file that failed for a network reason is left to the next pass', () async {
    queue.replace(files(OfflineVariant.thumbnail, 1));
    await queue.topUp();

    downloads.calls.values.single.completeError(const OfflineDownloadException('timeout'));
    await settle();

    // Not put back here: the queue may have been replaced meanwhile, and only a pass knows whether it is still wanted.
    expect(failed, isEmpty);
    expect(letGo, 1);
    expect(queue.isIdle, isTrue);
  });

  test('a thumbnail that keeps timing out while others arrive counts as a failure', () async {
    final stuck = files(OfflineVariant.thumbnail, 1);
    for (var attempt = 1; attempt <= 5; attempt++) {
      queue.replace([...stuck, ...files(OfflineVariant.thumbnail, 1, from: attempt)]);
      await queue.topUp();
      downloads.calls[stuck.single.file.url]!.completeError(const OfflineDownloadException('timeout'));
      downloads.calls['https://photos.example.com/api/assets/asset-$attempt/thumbnail']!.complete(10);
      await settle();
    }

    expect(failed.map((entry) => entry.assetId), ['asset-0']);
    expect(letGo, 4);
  });

  test('a download cancelled on the native side in the foreground is left to the next pass', () async {
    queue.replace(files(OfflineVariant.original, 1));
    await queue.topUp();

    downloads.calls.values.single.completeError(const OfflineDownloadCancelled());
    await settle();

    expect(letGo, 1);
    expect(queue.stoppedBecause, isNull);
  });

  test('a stop from the user while away holds until the app is on screen', () async {
    downloads.keptAlive = true;
    queue.replace(files(OfflineVariant.original, 2));
    await queue.topUp();
    await settle();
    queue.setSuspended(true);
    await settle();
    expect(downloads.calls, hasLength(2));

    // The user stops the transfer: the native side cancels everything and lets the keep-alive go.
    downloads.keptAlive = false;
    for (final call in downloads.calls.values) {
      call.completeError(const OfflineDownloadCancelled());
    }
    downloads.calls.clear();
    await settle();

    // The pass that follows queues them again, but nothing is handed to the system.
    queue.replace(files(OfflineVariant.original, 2));
    await queue.topUp();
    await settle();
    expect(downloads.calls, isEmpty);

    queue.setSuspended(false);
    await settle();
    expect(downloads.calls, hasLength(2));
  });

  test('an unexpected error does not stall the queue', () async {
    queue.replace(files(OfflineVariant.thumbnail, 7));
    downloads.throwOnFetch = StateError('boom');
    await queue.topUp();
    downloads.throwOnFetch = null;
    await settle();

    // Each failure is counted against its file and tops up again, so the seventh file starts once fetching works.
    expect(failed, hasLength(6));
    expect(letGo, 0);
    expect(downloads.calls, hasLength(1));
    expect(queue.pending, 0);
  });

  test('Wi-Fi only on another network starts nothing', () async {
    networkAllowed = false;
    queue.replace(files(OfflineVariant.thumbnail, 3));

    await queue.topUp();

    expect(queue.queued, 0);
    expect(queue.stoppedBecause, 'waiting for Wi-Fi');
  });

  test('a file already on disk is claimed instead of downloaded', () async {
    final entry = files(OfflineVariant.thumbnail, 1).single;
    final path = offlinePinnedPath(await offlineStoreRoot(), entry.file.name);
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(5, 1));
    queue.replace([entry]);

    await queue.topUp();

    expect(downloads.calls, isEmpty);
    expect(held.single.size, 5);
  });
}
