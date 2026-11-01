/// immich-sync fork: the passes, against a real database. The cases that matter are the ones where upstream's tables
/// are not what they look like: half-synced after a sign-in or a server reset.
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/offline_sync.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/utils/offline_files.dart';
import 'package:immich_mobile/infrastructure/repositories/offline.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_download.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

import '../../medium/repository_context.dart';

/// Downloads that never finish; these tests look at decisions, not transfers.
class _IdleDownloads extends OfflineDownloadRepository {
  @override
  Future<int> fetch(
    String url,
    String path, {
    OfflineLane lane = OfflineLane.light,
    String? checksum,
    bool wifiOnly = false,
    Future<void>? abort,
  }) => Completer<int>().future;

  @override
  Future<bool> keepAlive({required int pending, required bool wifiOnly}) async => false;

  @override
  Future<void> cancelAll() async {}
}

/// Holds the first pass that counts assets until [release], so a test can act while a pass has the lock.
class _GatedRepository extends OfflineRepository {
  _GatedRepository(super.db);

  final _gate = Completer<void>();
  final entered = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<int> assetCount() async {
    if (!entered.isCompleted) {
      entered.complete();
      await _gate.future;
    }
    return super.assetCount();
  }
}

/// A service over an in-memory database, with the native store answering as an empty phone with room to spare.
class OfflineServiceContext {
  late MediumRepositoryContext ctx;
  late OfflineFlagsRepository flags;
  late SettingsRepository settings;
  late OfflineSyncService service;
  late Directory root;
  late String ownerId;

  /// What the native side reports as free.
  int freeSpace = 1 << 40;

  Future<void> setUp() async {
    root = Directory.systemTemp.createTempSync('offline_sync');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => root.path);
    messenger.setMockMethodCallHandler(
      const MethodChannel('mirrich/offline_store'),
      (call) async => call.method == 'freeSpace' ? freeSpace : null,
    );

    ctx = MediumRepositoryContext();
    flags = await ctx.offlineFlags();
    settings = await SettingsRepository.ensureInitialized(ctx.db);
    ownerId = (await ctx.newUser()).id;
  }

  /// Built on demand, so a test can arrange the database it starts from.
  OfflineSyncService start({OfflineRepository? repository}) =>
      service = OfflineSyncService(repository ?? OfflineRepository(ctx.db), flags, _IdleDownloads(), settings);

  Future<void> select(OfflinePolicy policy) => settings.write(SettingsKey.offlinePolicy, policy.encode());

  /// What upstream's sign-out and server resets do: close the gate and wipe the remote tables. The sync that follows
  /// brings users back first.
  Future<void> upstreamReset() async {
    await SyncStreamRepository(ctx.db).reset();
    await ctx.newUser(id: ownerId);
  }

  Future<void> tearDown() async {
    await service.dispose();
    await SettingsRepository.reset();
    await ctx.dispose();
    root.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Once for the file: `Store` is bound to the first instance it sees.
  late MediumRepositoryContext storeDb;
  setUpAll(() async {
    storeDb = MediumRepositoryContext();
    await StoreService.init(storeRepository: StoreRepository(storeDb.db), listenUpdates: false);
    await StoreService.I.put(StoreKey.serverEndpoint, 'http://localhost:2283/api');
  });
  tearDownAll(() async {
    await StoreService.I.dispose();
    await storeDb.dispose();
  });

  late OfflineServiceContext t;

  setUp(() async {
    t = OfflineServiceContext();
    await t.setUp();
  });

  tearDown(() async {
    // Passes catch their errors into the status, which would otherwise pass a broken test.
    expect(t.service.current.lastError, isNull);
    await t.tearDown();
  });

  group('half-synced upstream', () {
    test('an album not synced yet stays selected', () async {
      // Signed back in: the assets are back, the album is not yet.
      await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      const albumId = 'album-not-synced-yet';
      await t.select(const OfflinePolicy(albums: {albumId: OfflineQuality.full}));

      await t.start().check(download: false);

      expect(t.service.policy.albums.keys, contains(albumId));
    });

    test('an album gone once upstream is complete is forgotten', () async {
      await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      const albumId = 'album-deleted-on-the-server';
      await t.select(const OfflinePolicy(albums: {albumId: OfflineQuality.full}));
      await t.flags.setUpstreamComplete();

      await t.start().check(download: false);

      expect(t.service.policy.albums.keys, isNot(contains(albumId)));
    });

    test('decisions about album items survive a reset until the album is back', () async {
      final album = await t.ctx.newRemoteAlbum(ownerId: t.ownerId);
      final asset = await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      await t.ctx.newRemoteAlbumAsset(albumId: album.id, assetId: asset.id);
      await t.select(OfflinePolicy(albums: {album.id: OfflineQuality.full}));
      await t.flags.setUpstreamComplete();
      await t.start().check(download: false);
      expect(t.service.wantedOf(asset.id).isWanted, isTrue);

      // Sign-out and back in: assets first, album later.
      await t.upstreamReset();
      await t.ctx.newRemoteAsset(id: asset.id, ownerId: t.ownerId);
      await t.service.check(download: false);

      expect(t.service.wantedOf(asset.id).isWanted, isTrue);
      expect(t.service.policy.albums.keys, contains(album.id));
    });

    test('a hand-saved item missing mid-sync is not forgotten', () async {
      final asset = await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      await t.start().fetchForOffline([asset.id]);

      // The asset is gone from upstream's tables for now; the sync has not brought it back.
      await t.upstreamReset();
      await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      await t.service.sync(download: false);

      expect((await t.flags.page(limit: 10)).map((want) => want.id), contains(asset.id));
    });

    test('eviction at the limit keeps library files of items not synced back yet', () async {
      final asset = await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      const policy = OfflinePolicy(library: OfflineQuality.full);
      await t.select(policy);
      await t.flags.setUpstreamComplete();
      await t.flags.derive(policy, DateTime.now());
      await t.flags.markHeld([
        OfflineHeldRow(name: 'a', assetId: asset.id, variant: OfflineVariant.thumbnail, token: 1, size: 1000),
        OfflineHeldRow(name: 'b', assetId: asset.id, variant: OfflineVariant.original, token: 1, size: 9000),
      ]);
      // Started on the stored files, so its index counts them.
      t.start();

      await t.upstreamReset();
      await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      await t.service.setStorageLimit(100);

      expect(await t.flags.heldBytes(), 10000);

      // Once upstream says it is complete and the item is still missing, it is a spare like any other.
      await t.flags.setUpstreamComplete();
      await t.service.setStorageLimit(50);
      expect(await t.flags.heldBytes(), 0);
    });

    test('the integrity pass waits for upstream to be complete', () async {
      await t.ctx.newRemoteAsset(ownerId: t.ownerId);

      expect(await t.start().reclaim(), isFalse);
      expect(await t.flags.reclaimPending(), isTrue);
    });
  });

  group('passes', () {
    /// Records every file [quality] asks of [assetId] as stored, so a pass finds nothing missing.
    Future<void> holdAll(String assetId, OfflineQuality quality) async {
      final asset = (await OfflineRepository(t.ctx.db).detailsFor([assetId]))[assetId]!;
      await t.flags.markHeld([
        for (final file in offlineFilesFor(asset, quality, videoForm: 'video/playback'))
          OfflineHeldRow(name: file.name, assetId: assetId, variant: file.variant, token: file.token, size: 10),
      ]);
    }

    Future<int> wantedRows() async => (await t.flags.page(limit: 100)).length;

    test('a settled pass does not run again until something moves', () async {
      final asset = await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      const policy = OfflinePolicy(library: OfflineQuality.preview);
      await t.select(policy);
      await t.flags.setUpstreamComplete();
      await t.flags.derive(policy, DateTime.now());
      await holdAll(asset.id, OfflineQuality.preview);
      await t.start().check();

      // Behind the service's back, so only a pass that runs would bring it back.
      await t.ctx.db.customStatement('DELETE FROM offline.wanted');
      await t.service.check();
      expect(await wantedRows(), 0);

      t.service.noteUpstreamChanged();
      await t.service.check();
      expect(await wantedRows(), 1);
    });

    test('eviction takes the least recently used spares and keeps the library', () async {
      final kept = await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      final older = await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      final newer = await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      final album = await t.ctx.newRemoteAlbum(ownerId: t.ownerId);
      await t.ctx.newRemoteAlbumAsset(albumId: album.id, assetId: kept.id);
      final policy = OfflinePolicy(albums: {album.id: OfflineQuality.thumbnail});
      await t.select(policy);
      await t.flags.setUpstreamComplete();
      await t.flags.derive(policy, DateTime.now());
      OfflineHeldRow file(String assetId) => OfflineHeldRow(
        name: '$assetId-file',
        assetId: assetId,
        variant: OfflineVariant.thumbnail,
        token: 1,
        size: 100,
      );
      await t.flags.markHeld([file(kept.id)], at: DateTime(2026, 1));
      await t.flags.markHeld([file(older.id)], at: DateTime(2026, 2));
      await t.flags.markHeld([file(newer.id)], at: DateTime(2026, 3));
      t.start();

      await t.service.setStorageLimit(250);

      final left = {for (final row in await t.flags.heldPage(limit: 10)) row.assetId};
      expect(left, {kept.id, newer.id});
    });

    test('moving an item to the locked folder deletes its files at the next pass', () async {
      final asset = await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      const policy = OfflinePolicy(library: OfflineQuality.preview);
      await t.select(policy);
      await t.flags.setUpstreamComplete();
      await t.flags.derive(policy, DateTime.now());
      await holdAll(asset.id, OfflineQuality.preview);
      await t.start().check(download: false);
      expect(await t.flags.heldPage(limit: 10), isNotEmpty);

      await (t.ctx.db.update(t.ctx.db.remoteAssetEntity)..where((row) => row.id.equals(asset.id))).write(
        const RemoteAssetEntityCompanion(visibility: Value(AssetVisibility.locked)),
      );
      t.service.noteUpstreamChanged();
      await t.service.check(download: false);

      expect(await t.flags.heldPage(limit: 10), isEmpty);
    });

    test('free up space takes spares and nothing the selection keeps', () async {
      final kept = await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      final spare = await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      final album = await t.ctx.newRemoteAlbum(ownerId: t.ownerId);
      await t.ctx.newRemoteAlbumAsset(albumId: album.id, assetId: kept.id);
      final policy = OfflinePolicy(albums: {album.id: OfflineQuality.thumbnail});
      await t.select(policy);
      await t.flags.setUpstreamComplete();
      await t.flags.derive(policy, DateTime.now());
      await holdAll(kept.id, OfflineQuality.thumbnail);
      await t.flags.markHeld([
        OfflineHeldRow(name: 'browsed', assetId: spare.id, variant: OfflineVariant.preview, token: 1, size: 10),
      ]);
      t.start();

      await t.service.freeUpSpace();

      expect({for (final row in await t.flags.heldPage(limit: 10)) row.assetId}, {kept.id});
    });
  });

  group('stopping while a pass runs', () {
    /// One item the library selection wants and nothing stored, so a pass that runs to the end queues its files.
    Future<_GatedRepository> missingFiles() async {
      await t.ctx.newRemoteAsset(ownerId: t.ownerId);
      const policy = OfflinePolicy(library: OfflineQuality.preview);
      await t.select(policy);
      await t.flags.setUpstreamComplete();
      await t.flags.derive(policy, DateTime.now());
      final repository = _GatedRepository(t.ctx.db);
      t.start(repository: repository);
      return repository;
    }

    int queued() => t.service.current.queued + t.service.current.pending;

    test('stopping downloads does not wait, and the pass does not queue what it found', () async {
      final repository = await missingFiles();
      final pass = t.service.sync();
      await repository.entered.future;

      await t.service.stopDownloads().timeout(const Duration(seconds: 1));
      repository.release();
      await pass;
      expect(queued(), 0);

      // The next pass queues them, so the one above did find something.
      await t.service.sync();
      expect(queued(), greaterThan(0));
    });

    test('a pass waiting for the lock when downloads stop does not queue what it finds either', () async {
      final repository = await missingFiles();
      final running = t.service.sync();
      await repository.entered.future;
      final waiting = t.service.sync();

      await t.service.stopDownloads();
      repository.release();
      await (running, waiting).wait;
      expect(queued(), 0);
    });

    test('pausing does not wait, and the pass does not queue what it found', () async {
      final repository = await missingFiles();
      final pass = t.service.sync();
      await repository.entered.future;

      await t.service.setPaused(true).timeout(const Duration(seconds: 1));
      expect(t.service.current.isPaused, isTrue);
      repository.release();
      await pass;

      expect(queued(), 0);
    });

    test('deleting everything interrupts the pass instead of waiting for it to finish', () async {
      final repository = await missingFiles();
      final pass = t.service.sync();
      await repository.entered.future;

      final wipe = t.service.deleteAll(forgetSelection: true);
      repository.release();
      await wipe;
      await pass;

      expect(queued(), 0);
      expect(await t.flags.page(limit: 10), isEmpty);
    });

    test('a pass waiting for the lock is interrupted too, so the wipe does not wait for it', () async {
      final repository = await missingFiles();
      final running = t.service.sync();
      await repository.entered.future;
      final order = <String>[];
      final waiting = t.service.sync().then((_) => order.add('waiting pass'));

      final wipe = t.service.deleteAll().then((_) => order.add('wipe'));
      repository.release();
      await (running, waiting, wipe).wait;

      // The waiting pass still runs first, but gives the lock up at once; nothing it found is queued.
      expect(order, ['waiting pass', 'wipe']);
      expect(queued(), 0);
    });
  });
}
