/// immich-sync fork: which files an asset needs offline, and under which names. Pure apart from the server endpoint and
/// the video setting the URLs read, so the queue, the browsing record and the integrity pass agree by construction.
library;

import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/infrastructure/repositories/offline.repository.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:openapi/api.dart' show AssetMediaSize;

/// The files an asset needs offline: the thumbnail always, the preview from the preview rung up, and the full-size
/// file at the rungs that ask for it. [videoForm] is `original` or `video/playback`; the current setting unless given.
List<OfflineFile> offlineFilesFor(
  OfflineAsset asset,
  OfflineQuality quality, {
  bool errand = false,
  String? videoForm,
}) {
  if (!quality.isWanted) {
    return const [];
  }

  // Nothing is fetchable before the server has a thumbhash: every URL would 404, and the thumbhash is part of the
  // name.
  if (asset.thumbHash.isEmpty) {
    return const [];
  }

  final files = [
    OfflineFile(getThumbnailUrlForRemoteId(asset.id, thumbhash: asset.thumbHash), OfflineVariant.thumbnail),
  ];

  // The full-size file is not fetched when the camera roll holds the item; the thumbnail and preview still are. An
  // errand overrides this: *Save offline* asks for this app's own copy.
  final localUsable = !errand && asset.localCopyUsable;

  // An errand also takes the top rung. Applied here rather than written to the row, whose rung the reclaim bands
  // read.
  final rung = errand ? kOfflineErrandQuality : quality;

  if (!rung.keepsPreview) {
    return files;
  }
  files.add(
    OfflineFile(
      getThumbnailUrlForRemoteId(asset.id, type: AssetMediaSize.preview, thumbhash: asset.thumbHash),
      OfflineVariant.preview,
    ),
  );

  if (asset.isImage) {
    if (rung.keepsOriginal && !localUsable) {
      files.add(
        OfflineFile(
          offlineOriginalUrl(asset.id, isEdited: asset.isEdited, thumbHash: asset.thumbHash),
          OfflineVariant.original,
          checksum: asset.originalChecksum,
        ),
      );
    }
    // A Live Photo's motion part is a file of this item, stored under the motion id the viewer asks for.
    final motion = asset.motionVideoId;
    if (motion != null && rung.videoTier != OfflineVideoTier.none && !localUsable) {
      files.add(OfflineFile(offlineVideoUrl(motion, form: videoForm), OfflineVariant.video));
    }
  } else {
    switch (rung.videoTier) {
      case OfflineVideoTier.none:
        break;
      case OfflineVideoTier.playback:
        if (!localUsable) {
          // The playback transcode has no checksum; the original file is the one the server hashed.
          final form = videoForm ?? offlineVideoForm();
          files.add(
            OfflineFile(
              offlineVideoUrl(asset.id, form: form),
              OfflineVariant.video,
              checksum: form == 'original' ? asset.originalChecksum : null,
            ),
          );
        }
    }
  }
  return files;
}
