/// immich-sync fork: every change to what the store holds goes through the ledger, which keeps the files, `held`, the
/// index and the native sets in step. Each path is checked against all four.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/utils/offline_index.dart';
import 'package:immich_mobile/domain/utils/offline_ledger.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

import '../../medium/repository_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late MediumRepositoryContext ctx;
  late OfflineFlagsRepository flags;
  late OfflineIndex index;
  late OfflineLedger ledger;
  late int recorded;
  late List<String> nativeStored;
  late List<String> nativeRemoved;
  late String root;

  setUp(() async {
    support = Directory.systemTemp.createTempSync('offline_ledger');
    nativeStored = [];
    nativeRemoved = [];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => support.path,
    );
    messenger.setMockMethodCallHandler(const MethodChannel('mirrich/offline_store'), (call) async {
      switch (call.method) {
        case 'noteStored':
          nativeStored.addAll((call.arguments as List).cast<String>());
        case 'noteRemoved':
          nativeRemoved.addAll((call.arguments as List).cast<String>());
      }
      return null;
    });
    ctx = MediumRepositoryContext();
    flags = await ctx.offlineFlags();
    index = OfflineIndex();
    recorded = 0;
    ledger = OfflineLedger(flags, index, onRecorded: () => recorded++);
    root = await offlineStoreRoot();
  });

  tearDown(() async {
    await ledger.dispose();
    await ctx.dispose();
    if (support.existsSync()) {
      support.deleteSync(recursive: true);
    }
  });

  OfflineHeldRow row(String name, {int token = 1}) =>
      OfflineHeldRow(name: name, assetId: 'a', variant: OfflineVariant.thumbnail, token: token, size: 3);

  File onDisk(String name) => File(offlinePinnedPath(root, name))
    ..createSync(recursive: true)
    ..writeAsBytesSync([1, 2, 3]);

  Future<List<String>> heldNames() async => [for (final held in await flags.heldPage(limit: 100)) held.name];

  test('an arrival counts at once and is written with the next flush', () async {
    ledger.record(row('one'), ledger.ticket());
    expect(index.heldBytes, 3);
    expect(await heldNames(), isEmpty);

    await ledger.flush();

    expect(await heldNames(), ['one']);
    expect(nativeStored, ['one']);
    expect(recorded, 1);
  });

  test('a reload replays arrivals not written yet', () async {
    ledger.record(row('one'), ledger.ticket());

    await ledger.reload();

    expect(index.holds('a', OfflineVariant.thumbnail, 1), isTrue);
    expect(index.heldBytes, 3);
  });

  test('an arrival replacing an older version deletes the old file everywhere', () async {
    final old = onDisk('old');
    await flags.markHeld([row('old')]);
    await ledger.reload();

    // An edit gives the thumbnail a new token, and with it a new name.
    onDisk('new');
    ledger.record(row('new', token: 2), ledger.ticket());
    await ledger.flush();

    expect(old.existsSync(), isFalse);
    expect(await heldNames(), ['new']);
    expect(nativeRemoved, ['old']);
    expect(index.heldBytes, 3);
  });

  test('removing takes a file from disk, rows, index and native sets', () async {
    final file = onDisk('one');
    await flags.markHeld([row('one')]);
    await ledger.reload();

    final failed = await ledger.remove([row('one')]);

    expect(failed, 0);
    expect(file.existsSync(), isFalse);
    expect(await heldNames(), isEmpty);
    expect(index.heldBytes, 0);
    expect(nativeRemoved, ['one']);
  });

  test('arrivals wait while the integrity pass walks, and are written after', () async {
    final walking = Completer<void>();
    final walked = ledger.walk(() => walking.future.then((_) => 0), changed: (_) => 0);
    await Future<void>.delayed(Duration.zero);
    ledger.record(row('during'), ledger.ticket());
    await ledger.flush();
    expect(await heldNames(), isEmpty);

    walking.complete();
    await walked;

    expect(await heldNames(), ['during']);
  });

  test('uses served before a failed write are kept for the retry', () async {
    await flags.markHeld([row('seen')], at: DateTime(2000));
    ledger.noteRead('seen');
    ledger.record(
      const OfflineHeldRow(name: 'new', assetId: 'b', variant: OfflineVariant.thumbnail, token: 1, size: 3),
      ledger.ticket(),
    );

    await ctx.db.customStatement(
      "CREATE TEMP TRIGGER fail BEFORE INSERT ON $kOfflineSchema.held BEGIN SELECT RAISE(ABORT, 'busy'); END",
    );
    await ledger.flush();
    await ctx.db.customStatement('DROP TRIGGER fail');
    await ledger.flush();

    final usedAt = await ctx.db
        .customSelect("SELECT used_at FROM $kOfflineSchema.held WHERE name = 'seen'")
        .map((r) => r.read<int>('used_at'))
        .getSingle();
    expect(usedAt, greaterThan(DateTime(2000).millisecondsSinceEpoch ~/ 1000));
  });

  test('a wipe forgets arrivals that land across it', () async {
    onDisk('one');
    await flags.markHeld([row('one')]);
    await ledger.reload();

    final noticed = ledger.ticket();
    await ledger.wipe(forgetSelection: false, stop: () async => ledger.record(row('late'), ledger.ticket()));
    // Noticed before the wipe, recorded after it: the ticket is stale, so the file is not the store's.
    ledger.record(row('later'), noticed);
    await ledger.flush();

    expect(Directory(root).existsSync(), isFalse);
    expect(await heldNames(), isEmpty);
    expect(index.heldBytes, 0);
  });
}
