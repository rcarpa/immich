/// immich-sync fork: fetching one file through the native downloader, and which failures count against it. Network
/// and session failures must not, or going off-grid gives up on the selection.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_download.repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/offline_store');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  void answer(Future<Object?> Function(MethodCall call) handler) {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  final repository = OfflineDownloadRepository(channel: channel);

  group('classifyOfflineFailure', () {
    test('no response says nothing about the file', () {
      expect(classifyOfflineFailure(null), OfflineFailureKind.transient);
    });

    test('a rejected session or an unavailable server says nothing about the file', () {
      for (final code in [401, 407, 408, 429, 502, 503, 504]) {
        expect(classifyOfflineFailure(code), OfflineFailureKind.transient, reason: '$code');
      }
    });

    test('the server answering about this file counts against it', () {
      for (final code in [400, 403, 404, 410, 500]) {
        expect(classifyOfflineFailure(code), OfflineFailureKind.file, reason: '$code');
      }
    });
  });

  test('asks the native side to download and returns the size', () async {
    answer((_) async => 42);

    expect(await repository.fetch('https://photos.example.com/a', '/store/ab/a'), 42);
    expect(calls.single.method, 'download');
    expect(calls.single.arguments, containsPair('url', 'https://photos.example.com/a'));
    expect(calls.single.arguments, containsPair('path', '/store/ab/a'));
    expect(calls.single.arguments, containsPair('lane', 'light'));
  });

  test('passes the lane, the checksum and Wi-Fi only along', () async {
    answer((_) async => 42);

    await repository.fetch(
      'https://photos.example.com/a',
      '/store/ab/a',
      lane: OfflineLane.heavy,
      checksum: 'c2hhMQ==',
      wifiOnly: true,
    );

    expect(calls.single.arguments, containsPair('lane', 'heavy'));
    expect(calls.single.arguments, containsPair('checksum', 'c2hhMQ=='));
    expect(calls.single.arguments, containsPair('wifiOnly', true));
  });

  test('bytes that are not the file count against it', () async {
    answer((_) async => throw PlatformException(code: 'integrity', message: 'Checksum mismatch'));

    await expectLater(
      repository.fetch('https://photos.example.com/a', '/store/ab/a'),
      throwsA(isA<OfflineDownloadException>().having((e) => e.kind, 'kind', OfflineFailureKind.file)),
    );
  });

  test('keeping alive reports what the native side says, and false where it cannot', () async {
    answer((_) async => true);
    expect(await repository.keepAlive(pending: 3, wifiOnly: false), isTrue);
    expect(calls.single.arguments, {'pending': 3, 'wifiOnly': false});

    messenger.setMockMethodCallHandler(channel, null);
    expect(await repository.keepAlive(pending: 3, wifiOnly: false), isFalse);
  });

  test('an HTTP error counts against the file by its status', () async {
    answer((_) async => throw PlatformException(code: 'http', message: 'HTTP 404', details: 404));

    await expectLater(
      repository.fetch('https://photos.example.com/a', '/store/ab/a'),
      throwsA(isA<OfflineDownloadException>().having((e) => e.kind, 'kind', OfflineFailureKind.file)),
    );
  });

  test('a network failure is transient', () async {
    answer((_) async => throw PlatformException(code: 'network', message: 'offline'));

    await expectLater(
      repository.fetch('https://photos.example.com/a', '/store/ab/a'),
      throwsA(isA<OfflineDownloadException>().having((e) => e.kind, 'kind', OfflineFailureKind.transient)),
    );
  });

  test('aborting cancels the native download and reads as cancelled, not failed', () async {
    final download = Completer<Object?>();
    answer((call) async {
      if (call.method == 'cancelDownload') {
        download.completeError(PlatformException(code: 'cancelled'));
        return null;
      }
      return download.future;
    });
    final abort = Completer<void>();

    final fetching = repository.fetch('https://photos.example.com/a', '/store/ab/a', abort: abort.future);
    abort.complete();

    await expectLater(fetching, throwsA(isA<OfflineDownloadCancelled>()));
    expect(calls.map((call) => call.method), ['download', 'cancelDownload']);
    expect(calls.last.arguments, (calls.first.arguments as Map)['id']);
  });
}
