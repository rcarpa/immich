/// immich-sync fork — which failed downloads count against their file (FORK.md §3.3).
///
/// Counting every failure alike gave up on the selection whenever the phone was off-grid or the session had expired,
/// which is the case the mirror exists for. Counting none would retry a photo the server cannot render for ever.
library;

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_download.repository.dart';

void main() {
  final task = DownloadTask(url: 'https://photos.example.com/api/assets/a/thumbnail', filename: 'a');

  OfflineFailureKind http(int code) =>
      classifyOfflineFailure(TaskStatusUpdate(task, TaskStatus.failed, TaskHttpException('HTTP $code', code)));

  test('no network says nothing about the file', () {
    final update = TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('offline'));
    expect(classifyOfflineFailure(update), OfflineFailureKind.transient);
  });

  test('a rejected session says nothing about the file', () {
    expect(http(401), OfflineFailureKind.transient);
  });

  test('a server that is down or overloaded says nothing about the file', () {
    for (final code in [408, 429, 502, 503, 504]) {
      expect(http(code), OfflineFailureKind.transient, reason: '$code');
    }
  });

  test('the server answering about this file counts against it', () {
    for (final code in [400, 403, 404, 410, 500]) {
      expect(http(code), OfflineFailureKind.file, reason: '$code');
    }
    expect(classifyOfflineFailure(TaskStatusUpdate(task, TaskStatus.notFound)), OfflineFailureKind.file);
  });

  test('the status code is read from the update when the exception carries none', () {
    final update = TaskStatusUpdate(task, TaskStatus.failed, TaskHttpException('?', -1), null, null, 401);
    expect(classifyOfflineFailure(update), OfflineFailureKind.transient);
  });

  test('anything unexplained counts, as it always did', () {
    final update = TaskStatusUpdate(task, TaskStatus.failed, TaskFileSystemException('disk'));
    expect(classifyOfflineFailure(update), OfflineFailureKind.file);
  });
}
