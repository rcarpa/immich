/// immich-sync fork — where an asset's bytes live on disk (FORK.md §3.4). The naming here is shared with
/// `ios/Runner/Images/OfflineStore.swift`, which reads it back on the image path.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Application Support, not Caches: iOS purges Caches under storage pressure.
const kOfflineRootDirectory = 'mirrich_blobs';

/// The fork's own database, and the schema name it is attached to upstream's connection under (FORK.md §3.2.1).
///
/// **Attached, not merged into upstream's schema.** Three reasons, in order of how badly each bites:
///
/// - `Drift.reset()` empties `sqlite_master` of `main` and vacuums, and the sync settings screen can reach it. Tables
///   in `main` would go with it, leaving every stored byte on disk with nothing left to describe it. An attached file
///   is untouched.
/// - Upstream's schema is a single `schemaVersion` integer with a step-by-step migrator and a committed snapshot per
///   version. Sharing that number line with an upstream we do not control cannot be made safe: whichever side
///   renumbers after shipping leaves installed databases stamped with a version that means something else.
/// - It keeps the fork out of upstream's generated migration files and its all-pairs migration test.
///
/// What the attachment buys is the only thing that matters: one connection, so a single statement can join what the
/// user selected against the assets, the albums and the camera roll.
const kOfflineSchema = 'offline';

const kOfflineDatabaseName = 'mirrich_offline.sqlite';

/// Where that file lives — beside the blobs in Application Support, not with upstream's database in Documents.
Future<String> offlineDatabasePath() async =>
    p.join((await getApplicationSupportDirectory()).path, kOfflineDatabaseName);

/// The one region every blob lives in — downloaded by the reconciler and kept by the image path alike. Named for the
/// days it was one of two; renaming it would cost every installed store a move for nothing.
const kOfflinePinnedDirectory = 'pinned';

/// The files one asset needs, in the order they are fetched.
enum OfflineVariant {
  thumbnail,
  preview,
  original,
  video;

  int get bit => 1 << index;

  /// Which batch of the download queue this file belongs to — cheapest and most useful first (FORK.md §3.3).
  int get fetchOrder => switch (this) {
    OfflineVariant.thumbnail => 0,
    OfflineVariant.preview => 1,
    OfflineVariant.original => 2,
    OfflineVariant.video => 3,
  };

  /// The expensive half of the ladder: an image's original and a video's playable file, as against the thumbnail and
  /// preview every rung asks for.
  bool get isFullSize => this == OfflineVariant.original || this == OfflineVariant.video;
}

/// What the downloader's holding queue is told about a file, where 0 is most urgent.
///
/// **Below every upload.** The mirror shares one downloader, one holding queue and one host with upstream's backup:
/// `Config.holdingQueue` in `main.dart` caps the lot at sixteen at once, and an upload task is priority 5
/// (`background_upload.service.dart`), or 0 for a Live Photo's companion. Sending a photo that exists nowhere else
/// matters more than copying back one the server already has, so nothing here may outrank 5. Anything that did would
/// let a flood of previews starve a backup, and `offline_queue_test.dart` pins the rule.
///
/// The queue's own order (FORK.md §3.3) is *decision first*, and a priority cannot say that: it is a small integer and
/// a decision is a timestamp. So this carries the part that fits — an errand above all standing work, and within
/// standing work the cheap half above the full-size one — and the hand-over window carries the rest, by bounding how
/// far behind an older decision a newer one can be queued: a window of small files, and few full-size ones.
int offlineTaskPriority(OfflineVariant variant, {required bool isErrand}) => isErrand ? 6 : 7 + variant.fetchOrder;

/// One file the mirror wants, named and keyed.
class OfflineFile {
  OfflineFile(this.url, this.variant) : _key = _keyFor(url);

  final String url;
  final OfflineVariant variant;
  final _BlobKey _key;

  String get name => _key.name;

  /// What tells this file apart from an earlier one of the same variant, so a superseded copy reads as missing:
  /// upstream's `c=<thumbhash>` cache buster, which moves on an edit, and for a video — whose URL carries no query — a
  /// fingerprint of the name the viewer setting produced.
  int get token => switch (variant) {
    OfflineVariant.thumbnail || OfflineVariant.preview || OfflineVariant.original => _key.token,
    OfflineVariant.video => _fnv1a32(_key.name),
  };
}

class _BlobKey {
  const _BlobKey(this.name, this.token);

  final String name;
  final int token;
}

// Everything below walks UTF-8 bytes, matching Swift's `String.utf8`.
const _dash = 0x2D;

bool _isSafe(int byte) =>
    (byte >= 0x30 && byte <= 0x39) ||
    (byte >= 0x41 && byte <= 0x5A) ||
    (byte >= 0x61 && byte <= 0x7A) ||
    byte == 0x2E ||
    byte == 0x5F ||
    byte == _dash;

String _sanitize(String value) => String.fromCharCodes(utf8.encode(value).map((byte) => _isSafe(byte) ? byte : _dash));

/// Orders by UTF-8 bytes, matching Swift's `utf8.lexicographicallyPrecedes`; `String.compareTo` would order by UTF-16
/// code unit.
int _compareUtf8(String a, String b) {
  final left = utf8.encode(a);
  final right = utf8.encode(b);
  final shared = left.length < right.length ? left.length : right.length;
  for (var i = 0; i < shared; i++) {
    if (left[i] != right[i]) {
      return left[i] - right[i];
    }
  }
  return left.length - right.length;
}

int _fnv1a32(String value) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(value)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// 64-bit name hash, so the integrity pass takes its wanted set as two megabytes of integers rather than ten megabytes
/// of strings.
int offlineNameHash(String name) {
  // 14695981039346656037, which is negative as a signed 64-bit int.
  var hash = -3750763034362895579;
  for (final byte in utf8.encode(name)) {
    hash = (hash ^ byte) * 1099511628211;
  }
  return hash;
}

/// Filename for a remote URL: the decoded path, the size, and a token over the rest of the query, which is how an
/// edited asset lands on a new name instead of serving stale bytes.
_BlobKey _keyFor(String url) {
  final uri = Uri.parse(url);
  final segments = [...uri.pathSegments.where((segment) => segment.isNotEmpty)];
  if (segments.isNotEmpty && segments.first == 'api') {
    segments.removeAt(0);
  }

  String? size;
  final params = <String>[];
  uri.queryParameters.forEach((key, value) {
    if (key == 'size') {
      size = value;
      return;
    }
    params.add('$key=$value');
  });
  params.sort(_compareUtf8);

  final token = _fnv1a32(params.join('&'));
  final buffer = StringBuffer(segments.map(_sanitize).join('_'));
  if (size != null) {
    buffer
      ..write('_')
      ..write(_sanitize(size!));
  }
  buffer.write('_${token.toRadixString(16).padLeft(8, '0')}');

  final name = buffer.toString();
  final playable = segments.contains('video') || (segments.isNotEmpty && segments.last == 'original');
  return _BlobKey(playable ? '$name.mp4' : name, token);
}

String offlineBlobName(String url) => _keyFor(url).name;

/// Bucket a name falls into. Hashed rather than taken from its first characters, which all read `assets_` and would
/// land in one directory.
String offlineBlobBucket(String name) => (_fnv1a32(name) & 0xFF).toRadixString(16).padLeft(2, '0');

/// Where `background_downloader` should put a file, relative to Application Support.
String offlinePinnedRelativeDirectory(String name) =>
    p.join(kOfflineRootDirectory, kOfflinePinnedDirectory, offlineBlobBucket(name));

/// The URL an original is stored and read under, shared by the reconciler, the viewer and the share sheet, so the three
/// cannot name the same bytes differently.
String offlineOriginalUrl(String assetId, {required bool isEdited, required String thumbHash, bool edited = true}) =>
    getOriginalUrlForRemoteId(assetId, edited: edited, thumbhash: isEdited && thumbHash.isNotEmpty ? thumbHash : null);

/// Which video the viewer asks for, and therefore which one is stored.
String offlineVideoForm() =>
    SettingsRepository.instance.appConfig.viewer.loadOriginalVideo ? 'original' : 'video/playback';

/// The URL a video is stored under, shared by the reconciler, the player and the share sheet: stored under one the
/// player never asks for, it is unplayable.
///
/// [form] names one other than the current setting's. The share sheet wants the original whatever the player asks for,
/// and a store filled before the setting changed may still hold it.
String offlineVideoUrl(String assetId, {String? form}) =>
    '${Store.get(StoreKey.serverEndpoint)}/assets/$assetId/${form ?? offlineVideoForm()}';

/// Resolved once: `getApplicationSupportDirectory()` is a channel round trip and this is consulted per file.
Future<String> offlineStoreRoot() async {
  final cached = _cachedRootPath;
  if (cached != null) {
    return cached;
  }
  final support = await getApplicationSupportDirectory();
  return _cachedRootPath = p.join(support.path, kOfflineRootDirectory);
}

String? _cachedRootPath;

String offlinePinnedPath(String root, String name) =>
    p.join(root, kOfflinePinnedDirectory, offlineBlobBucket(name), name);

/// Absolute path of a stored blob, or null. Finding one counts as using it, for eviction's sake.
Future<String?> offlineBlobPath(String url) async {
  final root = await offlineStoreRoot();
  final name = offlineBlobName(url);
  final path = offlinePinnedPath(root, name);
  if (!File(path).existsSync()) {
    return null;
  }
  offlineOnRead?.call(name);
  return path;
}

/// Told about every blob read through [offlineBlobPath] — the player and the share sheet, which do not go through the
/// native image path that reports its own reads. Set by the sync service.
void Function(String name)? offlineOnRead;

/// The size of a blob the device already has, so the queue records it instead of fetching it again — kept by the
/// image path and not yet reported, or left in the store by a selection since turned off.
int? offlineAdopt(String root, String name) {
  final file = File(offlinePinnedPath(root, name));
  if (!file.existsSync()) {
    return null;
  }
  try {
    return file.lengthSync();
  } catch (error) {
    Logger('OfflinePaths').warning('Could not measure a stored file; it will be fetched again: $name', error);
    return null;
  }
}

/// The asset a blob name belongs to, or null for a name that is not an asset's file (a face, say).
///
/// Names start with the URL's path segments joined by `_`, so an asset's files read `assets_<id>_…`, and an id is a
/// UUID, which has no `_` in it.
String? offlineAssetIdOf(String name) {
  final parts = name.split('_');
  if (parts.length < 3 || parts.first != 'assets' || parts[1].isEmpty) {
    return null;
  }
  return parts[1];
}

/// Which kind of file a name is, read from the shape of its URL — for a file the image path kept that is not one of the
/// variants the mirror tracks, so the storage figures still put it in the row it looks like. A full-size rendition is
/// filed with originals, and anything that is not an asset's file at all — a face — with thumbnails.
OfflineVariant offlineVariantOfName(String name) {
  final parts = name.split('_');
  if (offlineAssetIdOf(name) == null) {
    return OfflineVariant.thumbnail;
  }
  return switch (parts[2]) {
    'original' => OfflineVariant.original,
    'video' => OfflineVariant.video,
    'thumbnail' when parts.length > 3 && parts[3] == 'preview' => OfflineVariant.preview,
    'thumbnail' when parts.length > 3 && parts[3] == 'fullsize' => OfflineVariant.original,
    _ => OfflineVariant.thumbnail,
  };
}

/// Keeps the native lookup index in step with what Dart writes and deletes: it is built at launch and decides whether
/// the image path touches the filesystem at all, so a blob stored afterwards would otherwise stay invisible.
const _storeChannel = MethodChannel('mirrich/offline_store');

Future<void> offlineNoteStored(List<String> names) async {
  if (names.isEmpty) {
    return;
  }
  await _invoke('noteStored', names);
}

/// Names Dart has just deleted, dropped from the native index one by one. Cheaper than [offlineForgetIndex], which
/// rebuilds by walking the whole store — fine after a bulk removal, too slow for eviction, which runs while browsing.
Future<void> offlineNoteRemoved(List<String> names) async {
  if (names.isEmpty) {
    return;
  }
  await _invoke('noteRemoved', names);
}

Future<void> offlineForgetIndex() => _invoke('forgetAll', null);

/// Bytes free on the volume the store is on, or null where the platform cannot say.
Future<int?> offlineFreeSpace() async {
  try {
    return await _storeChannel.invokeMethod<int>('freeSpace');
  } on MissingPluginException {
    return null;
  } on PlatformException catch (error) {
    Logger('OfflinePaths').warning('Could not read the free space', error);
    return null;
  }
}

/// What the native image path did since it last reported: blobs it stored, with their sizes, and blobs it served.
typedef OfflineStoreActivity = ({List<(String, int)> stored, List<String> read});

/// Listens for [OfflineStoreActivity]. The native side batches it and sends it every couple of seconds while anything
/// is happening, so one call here covers many tiles.
void offlineListenForStoreActivity(void Function(OfflineStoreActivity activity) onActivity) {
  _storeChannel.setMethodCallHandler((call) async {
    if (call.method != 'activity') {
      throw MissingPluginException('${call.method} is not handled');
    }
    final arguments = call.arguments as Map<Object?, Object?>? ?? const {};
    final stored = <(String, int)>[];
    for (final entry in arguments['stored'] as List<Object?>? ?? const []) {
      if (entry is List && entry.length == 2 && entry[0] is String && entry[1] is int) {
        stored.add((entry[0] as String, entry[1] as int));
      }
    }
    final read = [
      for (final name in arguments['read'] as List<Object?>? ?? const [])
        if (name is String) name,
    ];
    onActivity((stored: stored, read: read));
  });
  // Said, not assumed: the background worker's engine registers the same channel, and the native side reports only to
  // the one that asked.
  unawaited(_invoke('listen', null));
}

Future<void> _invoke(String method, Object? arguments) async {
  try {
    await _storeChannel.invokeMethod<void>(method, arguments);
  } on MissingPluginException {
    // Nothing to keep in step off-device.
  }
}
