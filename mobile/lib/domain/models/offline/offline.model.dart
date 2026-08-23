/// immich-sync fork — the rows and figures the offline store is described by. Data only: what one selection says, what
/// one file on disk is, and the shapes the screen reports.
library;

import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

/// Where a page of the wanted list stopped — the three columns it is ordered by, so the next page is a cursor rather
/// than an `OFFSET`.
typedef OfflineWantCursor = ({int touchedAt, int createdAt, String id});

/// One asset wanted offline.
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

  /// What the row believes about the camera roll: that this phone holds a usable original, so the mirror fetches none
  /// and any full-size copy it does hold is a spare (§3.2). Recorded rather than joined, and therefore capable of being
  /// out of date — the pass that reads this row compares it with upstream and corrects it.
  final bool localCopy;

  OfflineWantCursor get cursor => (touchedAt: touchedAt, createdAt: createdAt, id: id);
}

/// A `wanted` row waiting to be written.
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

  /// Capture date. The one thing here that is also on the asset row, kept because it is the queue's sort key
  /// (`offline_flags.repository.dart`).
  final DateTime createdAt;

  /// When the change that produced this row was made.
  final DateTime touchedAt;

  /// Fetched because the user asked for this item once, not because a selection covers it.
  final bool onDemand;
}

/// Which files a reclaim covers, one kind per check box — the same four the storage overview lists.
///
/// A kind only gives up the files nothing bigger of the same item is keeping: a preview goes once no full-size copy of
/// its item stays, and a thumbnail once neither a preview nor a full-size copy does. That is what keeps every item in a
/// state the tile's bar can show — a full copy without the files that put it on the grid is not one.
enum OfflineReclaimKind { videos, originals, previews, thumbnails }

/// Why a held file is on the phone.
enum OfflineReclaimBand {
  /// The spares: nothing on the settings screen asks for this file.
  spares,

  /// The selection maintains these. Removing them pauses downloading, or the next pass would simply fetch them back.
  maintained;

  bool get pauses => this == OfflineReclaimBand.maintained;
}

/// One kind of file within one band — a cell of the grid the sheet draws, and the unit the whole reclaim is composed
/// from.
typedef OfflineReclaimCell = (OfflineReclaimBand, OfflineReclaimKind);

/// One reclaim, as the screen composes it: any set of cells.
class OfflineReclaim {
  const OfflineReclaim(this.cells);

  final Set<OfflineReclaimCell> cells;

  /// Every spare: what an album row's own figure offers, and what a caller that means "all of it" gets.
  static const notMaintained = OfflineReclaim({
    (OfflineReclaimBand.spares, OfflineReclaimKind.videos),
    (OfflineReclaimBand.spares, OfflineReclaimKind.originals),
    (OfflineReclaimBand.spares, OfflineReclaimKind.previews),
    (OfflineReclaimBand.spares, OfflineReclaimKind.thumbnails),
  });

  static const nothing = OfflineReclaim({});

  bool get isEmpty => cells.isEmpty;

  /// Whether downloading has to stop with it: only files a selection still asks for would otherwise come straight back.
  bool get pauses => cells.any((cell) => cell.$1.pauses);

  bool has(OfflineReclaimBand band, OfflineReclaimKind kind) => cells.contains((band, kind));

  /// The same choice with a whole band dropped, for a screen that has just stopped offering it.
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

  /// Assets touched, however many of their files go.
  final int assets;

  /// Each item counted once, by what it is left with — which is what the confirmation has to say, and a removal can take
  /// several kinds at once:
  ///
  /// - [removedItems] lose their thumbnail, and with it everything: they are gone from the device;
  /// - [losingPreviews] keep only their thumbnail: still in the grid, opening as that small picture;
  /// - [losingOriginals] keep their preview and lose the full-size photo;
  /// - [losingVideos] keep their still and lose the playable file — a video's, or a Live Photo's motion clip.
  final int removedItems;
  final int losingPreviews;
  final int losingOriginals;
  final int losingVideos;

  /// Of the items above, the ones fetched by hand — counted by media type, with what they take up, because that is the
  /// part of a removal nobody can see coming: nothing on the settings screen lists them, and they were asked for one at
  /// a time.
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

/// How the store's bytes are being used, on the two axes that decide whether they can go: does a selection maintain the
/// file, and which kind is it.
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

  /// Full-size photos a selection maintains.
  final int keptOriginalBytes;

  /// Playable video files a selection maintains.
  final int keptVideoBytes;

  /// Previews a selection maintains, videos' stills included.
  final int keptPreviewBytes;

  /// Thumbnails a selection maintains — every rung keeps one, and the lowest keeps nothing else.
  final int keptThumbnailBytes;

  /// Full-size photos nothing maintains: opened in the viewer, fetched on demand, left by a deselection, or left by a
  /// downgrade from full quality to previews.
  final int cachedOriginalBytes;

  /// Playable video files nothing maintains: fetched on demand, left by a deselection, or left by a library that has
  /// dropped below the video rung.
  final int cachedVideoBytes;

  /// Previews nothing maintains: what browsing kept, and the previews of items kept at the thumbnail rung.
  final int cachedPreviewBytes;

  /// Thumbnails nothing maintains, mostly what browsing kept — faces included, which are kept under their own name.
  final int cachedThumbnailBytes;

  /// Items that actually open with no network, which is what the screen reports: counting selections instead would say
  /// "nothing kept offline yet" over a working library.
  final int availableAssets;

  static const empty = OfflineStorage();

  /// What the storage screen calls the **library**: what the settings maintain, and nothing else.
  int get libraryOriginalBytes => keptOriginalBytes;
  int get libraryVideoBytes => keptVideoBytes;
  int get libraryPreviewBytes => keptPreviewBytes;
  int get libraryThumbnailBytes => keptThumbnailBytes;

  /// And **spares**: everything the settings do not ask for — what browsing kept, and hand-saved copies included. The
  /// least recently used of these are evicted when the store runs out of room.
  int get spareOriginalBytes => cachedOriginalBytes;
  int get spareVideoBytes => cachedVideoBytes;
  int get sparePreviewBytes => cachedPreviewBytes;
  int get spareThumbnailBytes => cachedThumbnailBytes;

  int get libraryBytes => libraryOriginalBytes + libraryVideoBytes + libraryPreviewBytes + libraryThumbnailBytes;
  int get spareBytes => spareOriginalBytes + spareVideoBytes + sparePreviewBytes + spareThumbnailBytes;

  /// Everything the app is holding, and what the storage limit is measured against.
  int get bytes => libraryBytes + spareBytes;

  /// What one cell of the reclaim grid holds.
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

/// One file known to be on disk.
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

/// Everything the availability index needs, one row per asset.
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

  /// Bitmask of [OfflineVariant]s on disk.
  final int held;

  /// Which generation the stored thumbnail/preview pair, original and video belong to.
  final int token;
  final int originalToken;
  final int videoToken;

  /// Whether the camera roll holds a usable original, so the mirror wants nothing beyond the preview (§3.2).
  ///
  /// In the index because the tile badge needs it synchronously and cannot get it from the asset it is drawing:
  /// `BaseAsset.hasLocal` is `localId != null`, and only some of upstream's timeline queries populate that column, so on
  /// the rest it reads false for a photo the phone certainly has.
  final bool localCopy;

  /// Whether *Save offline* is still outstanding for this item, which overrides [localCopy]: an errand asks for this
  /// app's own copy precisely because the camera roll's may be about to go.
  ///
  /// The third input to `filesFor`, and in the index for the same reason as the other two — without it the badge reports
  /// a target the downloader is already exceeding, and a hand-saved copy appears out of nowhere when it lands.
  final bool errand;

  /// Whether this row exists only because the item was fetched by hand, which makes every file of it a spare — the same
  /// reading `_unselectedOver` gives `on_demand`.
  final bool onDemand;
}

/// One section of a tile's bar (FORK.md §3.6). Each section is decided on its own, from its own files.
enum OfflineSegment {
  /// Not wanted, and not on the device. Drawn as nothing.
  empty,

  /// Wanted — by a setting or by *Save offline* — and not downloaded yet. The bare plate.
  waiting,

  /// Here, and a setting maintains it. White.
  done,

  /// Here, and no setting maintains it: browsed, saved by hand, or left by a change to the selection. Amber, as on the
  /// cleanup sheet's spares band — the same rule decides both (`_unselectedOver`).
  spare,
}

/// What a tile's bar draws: three fixed sections, one per kind of file, always in the same place.
typedef OfflineBar = ({
  /// The thumbnail.
  OfflineSegment thumbnail,

  /// The preview — a video's still included.
  OfflineSegment preview,

  /// The full copy: a photo's original, plus a Live Photo's motion clip where the rung asks for videos; a video's
  /// playable file.
  OfflineSegment full,
});

/// A bar with nothing to draw.
const OfflineBar kOfflineBarEmpty = (
  thumbnail: OfflineSegment.empty,
  preview: OfflineSegment.empty,
  full: OfflineSegment.empty,
);

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
    this.isWorking = false,
    this.isPaused = false,
    this.isOverLimit = false,
    this.revision = 0,
    this.lastError,
  });

  /// Items the user has asked to keep.
  final int wantedAssets;

  /// Files those items imply.
  final int wanted;

  /// Files on disk.
  final int held;

  /// Files the downloader is actually holding — handed over, and therefore either running or about to.
  ///
  /// Deliberately *not* the backlog. The two used to be one figure, and calling the sum "downloading" is how a queue
  /// that had stopped moving went on describing itself as busy: a pass planned three thousand files, handed none of them
  /// over because something told it not to, and the screen counted all three thousand as in progress for as long as the
  /// condition lasted.
  final int queued;

  /// Files a pass has planned and not yet handed over. Nothing is moving for these.
  final int pending;

  /// Downloads that gave up since the last pass. Retried by the next one.
  final int failed;

  /// Files of items upstream will not give us — in the trash, in the locked folder, or gone from the server since the
  /// selection was made.
  final int unavailable;

  /// Files the mirror deliberately does not fetch because the camera roll holds them (§3.2). Counted apart from
  /// [unavailable]: nothing is wrong with these, and reporting them beside downloading would make a deliberate saving
  /// read as a stack of failures. It belongs in **Storage**, as why the store is smaller than the selection implies.
  final int onDevice;

  final int bytes;
  final bool isWorking;

  /// Downloading is stopped until the user resumes it. Persisted.
  final bool isPaused;

  /// Downloading has stopped because the store reached the storage limit. Not the same state as [isPaused]: nothing was
  /// asked for, and it clears itself when space is freed or the limit is raised.
  final bool isOverLimit;

  /// Bumped when what is stored may have changed. The thumbnail badge watches this rather than [held], so it re-reads a
  /// few times a minute rather than several times a second.
  final int revision;

  final String? lastError;

  /// What progress is measured against: what was asked for, less what cannot be fetched at all and what does not need
  /// fetching.
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
    bool? isWorking,
    bool? isPaused,
    bool? isOverLimit,
    int? revision,
    String? lastError,
    bool clearError = false,
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
    isWorking: isWorking ?? this.isWorking,
    isPaused: isPaused ?? this.isPaused,
    isOverLimit: isOverLimit ?? this.isOverLimit,
    revision: revision ?? this.revision,
    lastError: clearError ? null : (lastError ?? this.lastError),
  );
}
