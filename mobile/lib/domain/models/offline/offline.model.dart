/// immich-sync fork: the rows and figures the offline store is described by.
library;

import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

/// Where a page of the wanted list stopped, so the next page is a cursor rather than an `OFFSET`.
typedef OfflineWantCursor = ({int touchedAt, int createdAt, String id});

class OfflineWant {
  const OfflineWant({
    required this.id,
    required this.quality,
    required this.createdAt,
    required this.touchedAt,
    this.localCopy = false,
  });

  final String id;
  final OfflineQuality quality;

  /// Capture date, which orders items a single change covers.
  final int createdAt;

  /// When the change that selected this item was made, in whole seconds.
  final int touchedAt;

  /// Whether the camera roll holds a usable original, read live with the row.
  final bool localCopy;

  OfflineWantCursor get cursor => (touchedAt: touchedAt, createdAt: createdAt, id: id);
}

class OfflineFlagRow {
  const OfflineFlagRow({
    required this.id,
    required this.quality,
    required this.createdAt,
    required this.touchedAt,
    this.onDemand = false,
  });

  final String id;
  final OfflineQuality quality;

  /// Capture date, the queue's sort key.
  final DateTime createdAt;

  final DateTime touchedAt;

  /// Fetched because the user asked for this item once, not because a selection covers it.
  final bool onDemand;
}

/// Which files a reclaim covers, one kind per check box. A kind only gives up files nothing bigger of the same item
/// keeps: a preview goes once no full-size copy stays, a thumbnail once neither a preview nor a full-size copy does.
enum OfflineReclaimKind { videos, originals, previews, thumbnails }

/// Why a held file is on the phone.
enum OfflineReclaimBand {
  /// Spares: nothing on the settings screen asks for these files.
  spares,

  /// Maintained by the selection. Removing them pauses downloading, or the next pass would fetch them back.
  maintained;

  bool get pauses => this == OfflineReclaimBand.maintained;
}

/// One kind of file within one band: a cell of the cleanup grid.
typedef OfflineReclaimCell = (OfflineReclaimBand, OfflineReclaimKind);

/// One reclaim, as the screen composes it: any set of cells.
class OfflineReclaim {
  const OfflineReclaim(this.cells);

  final Set<OfflineReclaimCell> cells;

  static const notMaintained = OfflineReclaim({
    (OfflineReclaimBand.spares, OfflineReclaimKind.videos),
    (OfflineReclaimBand.spares, OfflineReclaimKind.originals),
    (OfflineReclaimBand.spares, OfflineReclaimKind.previews),
    (OfflineReclaimBand.spares, OfflineReclaimKind.thumbnails),
  });

  static const nothing = OfflineReclaim({});

  bool get isEmpty => cells.isEmpty;

  /// Whether downloading has to stop, because a selection still asks for some of these files.
  bool get pauses => cells.any((cell) => cell.$1.pauses);

  bool has(OfflineReclaimBand band, OfflineReclaimKind kind) => cells.contains((band, kind));

  /// The same choice without a whole band.
  OfflineReclaim without(OfflineReclaimBand band) => OfflineReclaim({...cells}..removeWhere((cell) => cell.$1 == band));

  OfflineReclaim toggled(OfflineReclaimBand band, OfflineReclaimKind kind, {required bool on}) {
    final next = {...cells};
    if (on) {
      next.add((band, kind));
    } else {
      next.remove((band, kind));
    }
    return OfflineReclaim(next);
  }
}

/// What a reclaim would take back, in the terms the user experiences.
class OfflineReclaimPlan {
  const OfflineReclaimPlan({
    required this.files,
    required this.bytes,
    required this.assets,
    required this.removedItems,
    required this.losingPreviews,
    required this.losingOriginals,
    required this.losingVideos,
    required this.handVideos,
    required this.handVideoBytes,
    required this.handPhotos,
    required this.handPhotoBytes,
  });

  final int files;
  final int bytes;

  final int assets;

  /// Each item counted once, by what it is left with:
  ///
  /// - [removedItems] lose everything and are gone from the device;
  /// - [losingPreviews] keep only their thumbnail;
  /// - [losingOriginals] keep their preview and lose the full-size photo;
  /// - [losingVideos] keep their still and lose the playable file.
  final int removedItems;
  final int losingPreviews;
  final int losingOriginals;
  final int losingVideos;

  /// Of those, the items saved by hand, by media type: the part of a removal the settings screen never lists.
  final int handVideos;
  final int handVideoBytes;
  final int handPhotos;
  final int handPhotoBytes;

  int get handItems => handVideos + handPhotos;

  static const empty = OfflineReclaimPlan(
    files: 0,
    bytes: 0,
    assets: 0,
    removedItems: 0,
    losingPreviews: 0,
    losingOriginals: 0,
    losingVideos: 0,
    handVideos: 0,
    handVideoBytes: 0,
    handPhotos: 0,
    handPhotoBytes: 0,
  );

  bool get isEmpty => files == 0;

  OfflineReclaimPlan operator +(OfflineReclaimPlan other) => OfflineReclaimPlan(
    files: files + other.files,
    bytes: bytes + other.bytes,
    assets: assets + other.assets,
    removedItems: removedItems + other.removedItems,
    losingPreviews: losingPreviews + other.losingPreviews,
    losingOriginals: losingOriginals + other.losingOriginals,
    losingVideos: losingVideos + other.losingVideos,
    handVideos: handVideos + other.handVideos,
    handVideoBytes: handVideoBytes + other.handVideoBytes,
    handPhotos: handPhotos + other.handPhotos,
    handPhotoBytes: handPhotoBytes + other.handPhotoBytes,
  );
}

/// How the store's bytes divide: maintained by a selection or not, and by kind of file.
class OfflineStorage {
  const OfflineStorage({
    this.keptOriginalBytes = 0,
    this.keptVideoBytes = 0,
    this.keptPreviewBytes = 0,
    this.keptThumbnailBytes = 0,
    this.cachedOriginalBytes = 0,
    this.cachedVideoBytes = 0,
    this.cachedPreviewBytes = 0,
    this.cachedThumbnailBytes = 0,
    this.availableAssets = 0,
  });

  final int keptOriginalBytes;

  final int keptVideoBytes;

  final int keptPreviewBytes;

  final int keptThumbnailBytes;

  final int cachedOriginalBytes;

  final int cachedVideoBytes;

  final int cachedPreviewBytes;

  final int cachedThumbnailBytes;

  /// Items that open with no network.
  final int availableAssets;

  static const empty = OfflineStorage();

  /// The library: what the settings maintain.
  int get libraryOriginalBytes => keptOriginalBytes;
  int get libraryVideoBytes => keptVideoBytes;
  int get libraryPreviewBytes => keptPreviewBytes;
  int get libraryThumbnailBytes => keptThumbnailBytes;

  /// Spares: everything else. The least recently used are evicted when the store runs out of room.
  int get spareOriginalBytes => cachedOriginalBytes;
  int get spareVideoBytes => cachedVideoBytes;
  int get sparePreviewBytes => cachedPreviewBytes;
  int get spareThumbnailBytes => cachedThumbnailBytes;

  int get libraryBytes => libraryOriginalBytes + libraryVideoBytes + libraryPreviewBytes + libraryThumbnailBytes;
  int get spareBytes => spareOriginalBytes + spareVideoBytes + sparePreviewBytes + spareThumbnailBytes;

  /// Everything the app holds; what the storage limit is measured against.
  int get bytes => libraryBytes + spareBytes;

  int bytesFor(OfflineReclaimBand band, OfflineReclaimKind kind) {
    final (spare, kept) = switch (kind) {
      OfflineReclaimKind.videos => (cachedVideoBytes, keptVideoBytes),
      OfflineReclaimKind.originals => (cachedOriginalBytes, keptOriginalBytes),
      OfflineReclaimKind.previews => (cachedPreviewBytes, keptPreviewBytes),
      OfflineReclaimKind.thumbnails => (cachedThumbnailBytes, keptThumbnailBytes),
    };
    return switch (band) {
      OfflineReclaimBand.spares => spare,
      OfflineReclaimBand.maintained => kept,
    };
  }

  int bandBytes(OfflineReclaimBand band) =>
      OfflineReclaimKind.values.fold(0, (sum, kind) => sum + bytesFor(band, kind));

  bool get isEmpty => bytes == 0;
}

class OfflineHeldRow {
  const OfflineHeldRow({
    required this.name,
    required this.assetId,
    required this.variant,
    required this.token,
    required this.size,
  });

  final String name;
  final String assetId;
  final OfflineVariant variant;
  final int token;
  final int size;
}

class OfflineIndexRow {
  const OfflineIndexRow({
    required this.assetId,
    required this.quality,
    required this.isImage,
    required this.hasMotion,
    required this.held,
    required this.token,
    required this.originalToken,
    required this.videoToken,
    this.localCopy = false,
    this.errand = false,
    this.onDemand = false,
  });

  final String assetId;
  final OfflineQuality quality;
  final bool isImage;

  /// A Live Photo, so the top rung asks for one more file than an ordinary photo.
  final bool hasMotion;

  final int held;

  /// Which generation the stored thumbnail/preview pair, original and video belong to.
  final int token;
  final int originalToken;
  final int videoToken;

  /// Whether the camera roll holds a usable original. Kept in the index because the tile badge needs it synchronously,
  /// and `BaseAsset.hasLocal` is not populated by every timeline query.
  final bool localCopy;

  /// Whether *Save offline* is still outstanding, which overrides [localCopy].
  final bool errand;

  /// Whether the row exists only because the item was saved by hand, which makes all its files spares.
  final bool onDemand;
}

/// One section of a tile's bar, decided from its own files.
enum OfflineSegment {
  /// Not wanted and not here. Drawn as nothing.
  empty,

  /// Wanted and not downloaded yet. The bare plate.
  waiting,

  /// Here, and maintained by a setting. White.
  done,

  /// Here, and not maintained by a setting. Amber, as on the cleanup sheet's spares band.
  spare,
}

/// What a tile's bar draws: three fixed sections, one per kind of file.
typedef OfflineBar = ({
  OfflineSegment thumbnail,

  /// The preview, a video's still included.
  OfflineSegment preview,

  /// The full copy: a photo's original (plus a Live Photo's motion clip at the video rung), or a video's playable file.
  OfflineSegment full,
});

const OfflineBar kOfflineBarEmpty = (
  thumbnail: OfflineSegment.empty,
  preview: OfflineSegment.empty,
  full: OfflineSegment.empty,
);

/// What upstream knows about an item's full-size files, for the estimate of what is left to download. Sizes are 0 when
/// unknown; [isEdited] means `/original` returns the edit, whose size only the unedited original's approximates.
typedef OfflineSizes = ({int original, int motion, bool isEdited});

/// What the mirror is doing, for the screen and the app-bar badge.
class OfflineStatus {
  const OfflineStatus({
    this.wantedAssets = 0,
    this.wanted = 0,
    this.held = 0,
    this.queued = 0,
    this.pending = 0,
    this.failed = 0,
    this.unavailable = 0,
    this.onDevice = 0,
    this.bytes = 0,
    this.remainingBytes = 0,
    this.remainingIsExact = false,
    this.isWorking = false,
    this.isPaused = false,
    this.isOverLimit = false,
    this.refusedReclaim = 0,
    this.revision = 0,
    this.lastError,
    this.waitingBecause,
  });

  final int wantedAssets;

  final int wanted;

  final int held;

  /// Files downloading now. Not the planned backlog, which is [pending].
  final int queued;

  /// Files a pass has planned and not yet started. Nothing is moving for these.
  final int pending;

  /// Downloads that gave up since the last pass. Retried by the next one.
  final int failed;

  /// Files of items upstream will not give us: trashed, locked, or deleted since they were selected.
  final int unavailable;

  /// Files not fetched because the camera roll holds them. Not a failure; shown under Storage.
  final int onDevice;

  final int bytes;

  /// What is left to download (`OfflineIndex.remaining`): exact sizes for originals, averages for the rest.
  final int remainingBytes;

  /// Whether [remainingBytes] is made only of sizes the server reported, so the screen need not call it an estimate.
  final bool remainingIsExact;

  final bool isWorking;

  final bool isPaused;

  /// Stopped because the store reached its limit. Clears itself when space is freed or the limit raised.
  final bool isOverLimit;

  /// Files the integrity pass would have deleted but did not, as too large a share of the store to trust unprompted.
  final int refusedReclaim;

  /// Bumped when what is stored may have changed. Badges watch this rather than [held], so they redraw a few times a
  /// minute.
  final int revision;

  final String? lastError;

  /// Why planned files are not downloading, when they are not; from the queue.
  final String? waitingBecause;

  /// What progress is measured against: what was asked for, less what cannot or need not be fetched.
  int get fetchable => (wanted - unavailable - onDevice).clamp(0, wanted);

  int get missing => (fetchable - held).clamp(0, fetchable);

  bool get isComplete => fetchable > 0 && held >= fetchable;

  double get fraction => fetchable == 0 ? 0 : (held / fetchable).clamp(0, 1).toDouble();

  OfflineStatus copyWith({
    int? wantedAssets,
    int? wanted,
    int? held,
    int? queued,
    int? pending,
    int? failed,
    int? unavailable,
    int? onDevice,
    int? bytes,
    int? remainingBytes,
    bool? remainingIsExact,
    bool? isWorking,
    bool? isPaused,
    bool? isOverLimit,
    int? refusedReclaim,
    int? revision,
    String? lastError,
    bool clearError = false,
    String? waitingBecause,
    bool clearWaiting = false,
  }) => OfflineStatus(
    wantedAssets: wantedAssets ?? this.wantedAssets,
    wanted: wanted ?? this.wanted,
    held: held ?? this.held,
    queued: queued ?? this.queued,
    pending: pending ?? this.pending,
    failed: failed ?? this.failed,
    unavailable: unavailable ?? this.unavailable,
    onDevice: onDevice ?? this.onDevice,
    bytes: bytes ?? this.bytes,
    remainingBytes: remainingBytes ?? this.remainingBytes,
    remainingIsExact: remainingIsExact ?? this.remainingIsExact,
    isWorking: isWorking ?? this.isWorking,
    isPaused: isPaused ?? this.isPaused,
    isOverLimit: isOverLimit ?? this.isOverLimit,
    refusedReclaim: refusedReclaim ?? this.refusedReclaim,
    revision: revision ?? this.revision,
    lastError: clearError ? null : (lastError ?? this.lastError),
    waitingBecause: clearWaiting ? null : (waitingBecause ?? this.waitingBecause),
  );
}
