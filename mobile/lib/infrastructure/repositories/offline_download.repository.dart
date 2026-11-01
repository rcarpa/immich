import 'dart:async';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// immich-sync fork: the `background_downloader` group older builds downloaded in. Only used to cancel what they left.
const _legacyDownloadGroup = 'immich-sync-offline';

/// immich-sync fork: what a failed download says about the file, which decides whether it counts against the file.
enum OfflineFailureKind {
  /// The server answered about this file: not found, cannot be produced, refused for this asset. Counted.
  file,

  /// Nothing reached the server, or it could not answer anybody: no network, a timeout, a rejected session. Not
  /// counted; the queue holds off instead.
  transient,
}

/// Sorts a failure by its HTTP status, or null when no response arrived. A 403 is about one asset (a partner who
/// stopped sharing) and counts; a 401 is the session and does not. A 500 counts, since it is how the server reports a
/// file it cannot generate.
OfflineFailureKind classifyOfflineFailure(int? statusCode) => switch (statusCode) {
  null || 401 || 407 || 408 || 429 || 502 || 503 || 504 => OfflineFailureKind.transient,
  _ => OfflineFailureKind.file,
};

class OfflineDownloadException implements Exception {
  const OfflineDownloadException(this.message, {this.statusCode, this.isCorrupt = false});

  final String message;

  /// Null when no response arrived.
  final int? statusCode;

  /// The server answered, but what arrived is not the file: the wrong size, or a checksum that does not match. Counted
  /// against the file, since retrying for ever would download it for ever.
  final bool isCorrupt;

  OfflineFailureKind get kind => isCorrupt ? OfflineFailureKind.file : classifyOfflineFailure(statusCode);

  @override
  String toString() => message;
}

/// Thrown when a download is aborted on purpose.
class OfflineDownloadCancelled implements Exception {
  const OfflineDownloadCancelled();
}

/// immich-sync fork: how a file is downloaded natively.
enum OfflineLane {
  /// Thumbnails and previews: many small files, latency-bound, foreground only, never resumed.
  light,

  /// Originals and videos: few large files, bandwidth-bound. Resumed from where they stopped, verified, and carried on
  /// by the system once the app leaves the screen (a background `URLSession` on iOS, a user-initiated job or
  /// foreground service on Android).
  heavy,
}

/// immich-sync fork: fetches the mirror's files. The download itself runs natively (`OfflineDownloader.kt`,
/// `OfflineTransfers.swift`) through upstream's HTTP client, so no file bytes pass through Dart.
class OfflineDownloadRepository {
  OfflineDownloadRepository({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('mirrich/offline_store');

  final MethodChannel _channel;
  static final _log = Logger('OfflineDownloads');

  /// Request ids are unique across engines, since the native side keeps one table for every engine.
  final _engine = Random.secure().nextInt(1 << 32).toRadixString(16);
  var _counter = 0;

  /// Downloads [url] to [path] and returns its size; [path] only ever holds a complete, verified file. [checksum] is
  /// the server's base64 SHA-1 of the file, when it is known to describe these exact bytes. Throws
  /// [OfflineDownloadException], or [OfflineDownloadCancelled] once [abort] completes.
  Future<int> fetch(
    String url,
    String path, {
    OfflineLane lane = OfflineLane.light,
    String? checksum,
    bool wifiOnly = false,
    Future<void>? abort,
  }) async {
    final id = '$_engine-${_counter++}';
    var aborted = false;
    unawaited(
      abort?.then((_) {
        aborted = true;
        return _channel.invokeMethod<void>('cancelDownload', id).catchError((_) {});
      }),
    );
    try {
      final size = await _channel.invokeMethod<int>('download', {
        'id': id,
        'url': url,
        'path': path,
        'lane': lane.name,
        'checksum': checksum,
        'wifiOnly': wifiOnly,
      });
      if (size == null) {
        throw const OfflineDownloadException('No size returned');
      }
      return size;
    } on PlatformException catch (error) {
      if (error.code == 'cancelled' || aborted) {
        throw const OfflineDownloadCancelled();
      }
      final details = error.details;
      throw OfflineDownloadException(
        error.message ?? error.code,
        // Checked, not cast: a cast failing here would escape the queue's handlers and stall it.
        statusCode: error.code == 'http' && details is int ? details : null,
        isCorrupt: error.code == 'integrity',
      );
    } on MissingPluginException {
      throw const OfflineDownloadException('No native downloader');
    }
  }

  /// Cancels every native download, including ones a previous engine started and nobody waits for any more. Partial
  /// files are kept, so the next attempt resumes them.
  Future<void> cancelAll() async {
    try {
      await _channel.invokeMethod<void>('cancelAll');
    } on MissingPluginException {
      // Tests and platforms without the native downloader.
    } on PlatformException catch (error) {
      _log.warning('Could not cancel the native downloads', error);
    }
  }

  /// Tells the native side the queue still has [pending] files, so it keeps the process running while the app is in
  /// the background. A lease: it lapses unless renewed, so a Dart side that dies cannot keep it for ever. Returns
  /// whether the process is kept running, which only Android can do; elsewhere the queue gives way when backgrounded.
  Future<bool> keepAlive({required int pending, required bool wifiOnly}) async {
    try {
      return await _channel.invokeMethod<bool>('keepAlive', {'pending': pending, 'wifiOnly': wifiOnly}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      _log.warning('Could not keep the downloads running', error);
      return false;
    }
  }

  /// Cancels the downloads older builds left with `background_downloader`. Their finished files are claimed or swept
  /// like any other unrecorded file.
  static Future<void> cancelLegacyTasks() async {
    try {
      await FileDownloader().cancelAll(group: _legacyDownloadGroup);
    } catch (error) {
      _log.fine('Could not cancel downloads left by an older build', error);
    }
  }
}
