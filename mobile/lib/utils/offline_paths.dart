/// immich-sync fork: where an asset's files live on disk. Names come from the native core (`offline_name.rs`), which
/// `OfflineStore.swift` and `OfflineStore.kt` call too, so the reconciler and the image paths agree by construction.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:logging/logging.dart';
import 'package:native_core/native_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// From the native core, so the integrity pass gets its wanted set as integers rather than strings.
export 'package:native_core/native_core.dart' show offlineNameHash;

/// Application Support, not Caches: iOS purges Caches under storage pressure.
const kOfflineRootDirectory = 'mirrich_blobs';

/// The fork's own database, attached to upstream's connection under this schema name. Attached rather than merged, so
/// `Drift.reset()`, upstream's `schemaVersion` and its migration tests never touch it, while one statement can still
/// join the selection against upstream's assets, albums and camera roll.
const kOfflineSchema = 'offline';

const kOfflineDatabaseName = 'mirrich_offline.sqlite';

Future<String> offlineDatabasePath() async =>
    p.join((await getApplicationSupportDirectory()).path, kOfflineDatabaseName);

/// The directory every file lives in, whoever stored it. The name is historical.
const kOfflinePinnedDirectory = 'pinned';

enum OfflineVariant {
  thumbnail,
  preview,
  original,
  video;

  int get bit => 1 << index;

  int get fetchOrder => switch (this) {
    OfflineVariant.thumbnail => 0,
    OfflineVariant.preview => 1,
    OfflineVariant.original => 2,
    OfflineVariant.video => 3,
  };

  /// The expensive half: an image's original or a video's playable file.
  bool get isFullSize => this == OfflineVariant.original || this == OfflineVariant.video;
}

class OfflineFile {
  OfflineFile(this.url, this.variant, {this.checksum}) : name = offlineBlobName(url);

  final String url;
  final OfflineVariant variant;

  /// The server's base64 SHA-1 of exactly these bytes, which the download is verified against. Only for an unedited
  /// original of an uploaded asset: an edit is served from another file, and an external library's checksum hashes the
  /// path, not the content.
  final String? checksum;

  final String name;

  /// Tells this file apart from an older one of the same variant: upstream's `c=<thumbhash>` cache buster, or for a
  /// video a fingerprint of its URL.
  int get token => switch (variant) {
    OfflineVariant.thumbnail || OfflineVariant.preview || OfflineVariant.original => offlineToken(name) ?? 0,
    OfflineVariant.video => offlineVideoToken(name),
  };
}

/// Filename for a remote URL, from the native core, which the image paths of both platforms also name files with.
String offlineBlobName(String url) {
  final name = offlineFileName(url);
  if (name == null) {
    throw ArgumentError.value(url, 'url', 'has a malformed escape');
  }
  return name;
}


/// What a file stored under the server's path prefix (`immich_api_assets_…`, from builds that kept it) is called now,
/// or null for a name that never had one.
String? offlineUnprefixedName(String name) {
  final parts = name.split('_');
  for (var i = parts.length - 2; i > 0; i--) {
    if (parts[i] == 'api' && (parts[i + 1] == 'assets' || parts[i + 1] == 'people')) {
      return parts.sublist(i + 1).join('_');
    }
  }
  return null;
}

/// Bucket a name falls into, hashed so names sharing a prefix spread out.
String offlineBlobBucket(String name) => offlineBucket(name).toRadixString(16).padLeft(2, '0');

/// The URL an original is stored and read under, shared by the reconciler, the viewer and the share sheet.
String offlineOriginalUrl(String assetId, {required bool isEdited, required String thumbHash, bool edited = true}) =>
    getOriginalUrlForRemoteId(assetId, edited: edited, thumbhash: isEdited && thumbHash.isNotEmpty ? thumbHash : null);

/// The token the thumbnail and preview of [assetId]'s current version end in, for upstream's [thumbHash]. Names leave
/// the server address out, so any endpoint gives the same token.
int offlineVersionToken(String assetId, String thumbHash) => OfflineFile(
  getThumbnailUrlForRemoteId(assetId, thumbhash: thumbHash, endpoint: 'https://offline.invalid/api'),
  OfflineVariant.thumbnail,
).token;

String offlineVideoForm() =>
    SettingsRepository.instance.appConfig.viewer.loadOriginalVideo ? 'original' : 'video/playback';

/// The URL a video is stored under, shared by the reconciler, the player and the share sheet. [form] picks another than
/// the current setting's: sharing wants the original.
String offlineVideoUrl(String assetId, {String? form}) =>
    '${Store.get(StoreKey.serverEndpoint)}/assets/$assetId/${form ?? offlineVideoForm()}';

/// Resolved once: the lookup is a channel round trip and this is used per file.
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

/// Absolute path of a stored file, or null. Finding one counts as using it.
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

/// Told about every file read through [offlineBlobPath], which the native side does not report. Set by the sync
/// service.
void Function(String name)? offlineOnRead;

/// The size of a file already on disk, so the queue records it instead of fetching it again. An empty file is what an
/// interrupted write can leave, so it counts as missing and is fetched again, which replaces it.
int? offlineAdopt(String root, String name) {
  final file = File(offlinePinnedPath(root, name));
  if (!file.existsSync()) {
    return null;
  }
  try {
    final size = file.lengthSync();
    return size > 0 ? size : null;
  } catch (error) {
    Logger('OfflinePaths').warning('Could not measure a stored file; it will be fetched again: $name', error);
    return null;
  }
}

/// [offlineAdopt] for many files at once, off the UI isolate. Only the files found are in the result; one that cannot
/// be measured, or is empty, is fetched again.
Future<Map<String, int>> offlineAdoptAll(String root, List<String> names) => Isolate.run(() {
  final sizes = <String, int>{};
  for (final name in names) {
    try {
      final stat = File(offlinePinnedPath(root, name)).statSync();
      if (stat.type == FileSystemEntityType.file && stat.size > 0) {
        sizes[name] = stat.size;
      }
    } catch (_) {
      // Fetched again.
    }
  }
  return sizes;
});

/// The asset a file name belongs to, or null for other files such as faces. Names start `assets_<id>_`, and ids have no
/// `_`.
String? offlineAssetIdOf(String name) {
  final parts = name.split('_');
  if (parts.length < 3 || parts.first != 'assets' || parts[1].isEmpty) {
    return null;
  }
  return parts[1];
}

/// Which kind of file a name looks like, for files that are not a tracked variant. Full-size renditions count as
/// originals, anything else (faces) as thumbnails.
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

/// Tells the native lookup index about stored files; it is built at launch and decides whether the image path checks
/// the disk at all.
const _storeChannel = MethodChannel('mirrich/offline_store');

Future<void> offlineNoteStored(List<String> names) async {
  if (names.isEmpty) {
    return;
  }
  await _invoke('noteStored', names);
}

/// Drops deleted names from the native index one by one; cheaper than [offlineForgetIndex], which rescans the store.
Future<void> offlineNoteRemoved(List<String> names) async {
  if (names.isEmpty) {
    return;
  }
  await _invoke('noteRemoved', names);
}

Future<void> offlineForgetIndex() => _invoke('forgetAll', null);

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

/// What the native image path did since it last reported: files stored, with their sizes, and files served.
typedef OfflineStoreActivity = ({List<(String, int)> stored, List<String> read});

/// Listens for [OfflineStoreActivity], batched by the native side every couple of seconds.
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
  // Explicit, because the background worker's engine registers the same channel. Only the app's own engine is
  // accepted natively, so a background engine cannot take the reports away from it.
  unawaited(
    _storeChannel
        .invokeMethod<bool>('listen')
        .then((accepted) {
          if (accepted == false) {
            Logger('OfflinePaths').fine('Not the app engine; the image path reports elsewhere');
          }
        })
        .catchError((Object _) {}, test: (error) => error is MissingPluginException),
  );
}

Future<void> _invoke(String method, Object? arguments) async {
  try {
    await _storeChannel.invokeMethod<void>(method, arguments);
  } on MissingPluginException {
    // Tests and platforms without the native store.
  }
}
