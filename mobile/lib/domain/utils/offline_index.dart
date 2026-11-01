/// immich-sync fork: what is wanted and what is here, in memory. Tile badges and the reconciler both need the answer
/// with no I/O.
library;

import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

class _Entry {
  _Entry(
    this.quality,
    this.isImage,
    this.hasMotion,
    this.held,
    this.token,
    this.originalToken,
    this.videoToken, {
    this.localCopy = false,
    this.errand = false,
    this.onDemand = false,
  });

  OfflineQuality quality;

  /// The original's size from upstream's EXIF, and a Live Photo's motion part's; 0 until looked up
  /// ([OfflineIndex.idsLackingSizes]), or when upstream does not know.
  int originalBytes = 0;
  int motionBytes = 0;

  /// `/original` returns the edit, whose size [originalBytes] (the unedited file's) only approximates.
  bool isEdited = false;
  bool isImage;

  /// Whether the camera roll holds a usable original. Describes the device, so recording a decision must not change it.
  bool localCopy;

  /// Whether *Save offline* is still outstanding, which overrides [localCopy].
  bool errand;

  /// Whether the row exists only because the item was saved by hand; all its files are then spares.
  bool onDemand;

  /// A Live Photo: its motion part is a fourth file, wanted at the top rung.
  bool hasMotion;

  int held;

  /// Which version is stored, so an outdated copy reads as missing.
  int token;
  int originalToken;
  int videoToken;
}

/// Thumbnail and preview sizes before enough are stored to learn them: Immich's WebP thumbnail and 1440 px preview.
const _defaultThumbnailBytes = 16 * 1024;
const _defaultPreviewBytes = 170 * 1024;

/// Originals and videos whose size upstream does not know yet, before any known size can stand in for them.
const _defaultOriginalBytes = 3 * 1024 * 1024;
const _defaultVideoBytes = 30 * 1024 * 1024;

/// How many files an average needs before it replaces the default.
const _learnAfter = 20;

/// What is left to download, and whether every byte of it is a size the server reported.
typedef OfflineRemaining = ({int bytes, bool exact});

class OfflineIndex {
  final Map<String, _Entry> _entries = {};

  /// Files that arrived this session and their bytes, by [OfflineVariant.index]: what thumbnails and previews average.
  /// Learned from arrivals rather than read from the store, which would mean a query over every stored file.
  final _variantFiles = List.filled(OfflineVariant.values.length, 0);
  final _variantBytes = List.filled(OfflineVariant.values.length, 0);

  /// Videos that arrived this session with a known original, to learn how much a playback transcode keeps.
  var _videoSample = (files: 0, stored: 0, originals: 0);

  /// Whether an item's full-size sizes are still to be looked up.
  bool lacksSizes(String assetId) => (_entries[assetId]?.originalBytes ?? 1) == 0;

  /// Items with a full-size file still to download whose sizes are not known yet. Looked up once, so what is left is
  /// the server's sizes rather than an average; each file that lands then comes off it.
  List<String> idsLackingSizes() {
    final fullSize = OfflineVariant.original.bit | OfflineVariant.video.bit;
    return [
      for (final MapEntry(key: id, value: entry) in _entries.entries)
        if (entry.originalBytes == 0 && _fetched(entry) & ~entry.held & fullSize != 0) id,
    ];
  }

  /// Records what upstream knows about these items' full-size files.
  void applySizes(Map<String, OfflineSizes> sizes) {
    sizes.forEach((id, size) {
      final entry = _entries[id];
      if (entry == null) {
        return;
      }
      entry
        ..originalBytes = size.original
        ..motionBytes = size.motion
        ..isEdited = size.isEdited;
    });
    _restate();
  }

  static OfflineIndex? _live;

  /// Availability without a `ref`, for upstream's plain `ImageProvider`s.
  static OfflineAvailability availability(String assetId) => _live?.availabilityOf(assetId) ?? OfflineAvailability.none;

  void publish() => _live = this;

  /// The status figures, recounted from the entries on demand rather than maintained alongside them.
  ({int wantedAssets, int wantedFiles, int heldFiles})? _tally;

  ({int wantedAssets, int wantedFiles, int heldFiles}) get _counts {
    final cached = _tally;
    if (cached != null) {
      return cached;
    }
    var assets = 0;
    var files = 0;
    var held = 0;
    for (final entry in _entries.values) {
      if (!entry.quality.isWanted) {
        continue;
      }
      assets++;
      files += _filesFor(entry.quality, entry.isImage, entry.hasMotion);
      held += _heldCount(entry.held);
    }
    return _tally = (wantedAssets: assets, wantedFiles: files, heldFiles: held);
  }

  void _restate() {
    _tally = null;
    _remaining = null;
  }

  ({bool originalVideos, OfflineRemaining value})? _remaining;

  /// The bytes still to download for what is wanted. Exact where upstream's size is known: an unedited original, or a
  /// video kept as its original ([originalVideos]). Averaged where it is not: thumbnails and
  /// previews by what arrived, full-size files not yet queued by the known ones, playback videos by how much smaller
  /// the arrived ones came out than their originals. [OfflineRemaining.exact] when every byte is of the first kind,
  /// which is the case once what is left fits in one pass.
  OfflineRemaining remaining({required bool originalVideos}) {
    final cached = _remaining;
    if (cached != null && cached.originalVideos == originalVideos) {
      return cached.value;
    }
    final value = _estimateRemaining(originalVideos: originalVideos);
    _remaining = (originalVideos: originalVideos, value: value);
    return value;
  }

  OfflineRemaining _estimateRemaining({required bool originalVideos}) {
    var estimated = false;
    var thumbnails = 0;
    var previews = 0;
    var exact = 0;
    var unknownOriginals = 0;
    var videoSources = 0;
    var unknownVideos = 0;

    // Known sizes, to stand in for unknown ones.
    var knownImageBytes = 0;
    var knownImages = 0;
    var knownVideoBytes = 0;
    var knownVideos = 0;

    final thumbnail = OfflineVariant.thumbnail.bit;
    final preview = OfflineVariant.preview.bit;
    final original = OfflineVariant.original.bit;
    final video = OfflineVariant.video.bit;

    for (final entry in _entries.values) {
      final source = entry.isImage ? entry.motionBytes : entry.originalBytes;
      if (entry.isImage && entry.originalBytes > 0) {
        knownImageBytes += entry.originalBytes;
        knownImages++;
      }
      if (source > 0) {
        knownVideoBytes += source;
        knownVideos++;
      }

      final missing = _fetched(entry) & ~entry.held;
      if (missing == 0) {
        continue;
      }
      if (missing & thumbnail != 0) {
        thumbnails++;
      }
      if (missing & preview != 0) {
        previews++;
      }
      if (missing & original != 0) {
        if (entry.originalBytes > 0) {
          exact += entry.originalBytes;
          estimated |= entry.isEdited;
        } else {
          unknownOriginals++;
        }
      }
      if (missing & video != 0) {
        if (source > 0) {
          videoSources += source;
          // A Live Photo's motion part is its own asset, never edited; a video's edit would change its file.
          estimated |= !entry.isImage && entry.isEdited;
        } else {
          unknownVideos++;
        }
      }
    }
    estimated |= thumbnails > 0 || previews > 0 || unknownOriginals > 0 || unknownVideos > 0;
    estimated |= !originalVideos && (videoSources > 0);

    int average(OfflineVariant variant, int fallback) {
      final files = _variantFiles[variant.index];
      return files >= _learnAfter ? _variantBytes[variant.index] ~/ files : fallback;
    }

    final imageStandIn = knownImages > 0 ? knownImageBytes ~/ knownImages : _defaultOriginalBytes;
    final videoStandIn = knownVideos > 0 ? knownVideoBytes ~/ knownVideos : _defaultVideoBytes;

    // A playback file is a transcode, whose size the server only knows once made. Until enough are stored, assume it is
    // as large as its original, so the estimate errs high rather than promising too little.
    var videoRatio = 1.0;
    final sample = _videoSample;
    if (!originalVideos && sample.files >= _learnAfter && sample.originals > 0) {
      videoRatio = (sample.stored / sample.originals).clamp(0.05, 1.5);
    }

    final bytes =
        thumbnails * average(OfflineVariant.thumbnail, _defaultThumbnailBytes) +
        previews * average(OfflineVariant.preview, _defaultPreviewBytes) +
        exact +
        unknownOriginals * imageStandIn +
        ((videoSources + unknownVideos * videoStandIn) * videoRatio).round();
    return (bytes: bytes, exact: !estimated);
  }

  /// The variant bits an entry downloads, as `filesFor` decides them: the rung, lifted by an errand, and without the
  /// full-size files the camera roll holds unless an errand asked for them.
  static int _fetched(_Entry entry) {
    final rung = entry.errand ? kOfflineErrandQuality : entry.quality;
    if (!rung.isWanted) {
      return 0;
    }
    var bits = OfflineVariant.thumbnail.bit;
    if (!rung.keepsPreview) {
      return bits;
    }
    bits |= OfflineVariant.preview.bit;
    if (!entry.errand && entry.localCopy) {
      return bits;
    }
    final videos = rung.videoTier != OfflineVideoTier.none;
    if (entry.isImage) {
      if (rung.keepsOriginal) {
        bits |= OfflineVariant.original.bit;
      }
      if (entry.hasMotion && videos) {
        bits |= OfflineVariant.video.bit;
      }
    } else if (videos) {
      bits |= OfflineVariant.video.bit;
    }
    return bits;
  }

  int get wantedAssets => _counts.wantedAssets;

  /// Files the current selection implies, so progress is exact without anything being listed.
  int get wantedFiles => _counts.wantedFiles;

  int get heldFiles => _counts.heldFiles;
  int get heldBytes => _storeBytes;

  static int _heldCount(int held) {
    var count = 0;
    for (var bits = held; bits != 0; bits &= bits - 1) {
      count++;
    }
    return count;
  }

  static int _filesFor(OfflineQuality quality, bool isImage, bool hasMotion) {
    if (!quality.isWanted) {
      return 0;
    }
    // A thumbnail at every rung and a preview above the lowest, for photos and videos alike.
    if (!quality.keepsPreview) {
      return 1;
    }
    final big = isImage ? quality.keepsOriginal : quality.videoTier != OfflineVideoTier.none;
    // A Live Photo's motion part on top of its original.
    final motion = isImage && hasMotion && quality.videoTier != OfflineVideoTier.none;
    return (big ? 3 : 2) + (motion ? 1 : 0);
  }

  void load(List<OfflineIndexRow> rows, {required int heldBytes}) {
    // Sizes looked up so far survive a reload, which happens after every re-derivation.
    final sizes = {
      for (final MapEntry(key: id, value: entry) in _entries.entries)
        if (entry.originalBytes > 0)
          id: (original: entry.originalBytes, motion: entry.motionBytes, isEdited: entry.isEdited),
    };
    _entries.clear();
    _restate();
    for (final row in rows) {
      _entries[row.assetId] = _Entry(
        row.quality,
        row.isImage,
        row.hasMotion,
        row.held,
        row.token,
        row.originalToken,
        row.videoToken,
        localCopy: row.localCopy,
        errand: row.errand,
        onDemand: row.onDemand,
      );
    }
    applySizes(sizes);
    _storeBytes = heldBytes;
  }

  int _storeBytes = 0;

  OfflineQuality wantedOf(String assetId) => _entries[assetId]?.quality ?? OfflineQuality.none;

  /// Whether the camera roll holds a usable original. The badge asks this because `BaseAsset.hasLocal` is not populated
  /// by every timeline query.
  bool localCopyOf(String assetId) => _entries[assetId]?.localCopy ?? false;

  /// Records what a pass read about the camera roll. Separate from [setWanted], which must not reset it.
  void noteLocalCopy(String assetId, {required bool localCopy}) {
    final entry = _entries[assetId];
    if (entry != null) {
      entry.localCopy = localCopy;
    }
  }

  /// Whether *Save offline* is still outstanding, which makes the whole item the target.
  bool errandOf(String assetId) => _entries[assetId]?.errand ?? false;

  void noteErrand(String assetId, {required bool errand}) {
    final entry = _entries[assetId];
    if (entry != null) {
      entry.errand = errand;
    }
  }

  /// The three sections of a tile's bar: thumbnail, preview and full copy.
  ///
  /// What is fetched follows `filesFor` (the rung, capped by the camera roll, lifted by an errand); what is maintained
  /// follows `_unselectedOver` (the same without the errand, nothing for hand-saved rows). A section is waiting while
  /// something it fetches is missing, done once all of it is here and maintained, and spare when it holds anything not
  /// maintained.
  OfflineBar barOf(String assetId) {
    final entry = _entries[assetId];
    if (entry == null) {
      return kOfflineBarEmpty;
    }

    final fetching = entry.errand ? kOfflineErrandQuality : entry.quality;
    final maintaining = entry.onDemand ? OfflineQuality.none : entry.quality;
    // The camera roll caps the full-size half of what is fetched (unless an errand asked) and of what is maintained.
    final fetchCapped = !entry.errand && entry.localCopy;
    final maintainCapped = entry.localCopy;

    // The files of the full-copy section a rung asks for, as variant bits.
    int fullFiles(OfflineQuality rung, {required bool capped}) {
      if (!rung.isWanted || capped) {
        return 0;
      }
      final videos = rung.videoTier != OfflineVideoTier.none;
      if (!entry.isImage) {
        return videos ? OfflineVariant.video.bit : 0;
      }
      return (rung.keepsOriginal ? OfflineVariant.original.bit : 0) |
          (entry.hasMotion && videos ? OfflineVariant.video.bit : 0);
    }

    OfflineSegment segment({required int all, required int wanted, required int maintained}) {
      final held = entry.held & all;
      if (wanted != 0) {
        if (held & wanted != wanted) {
          return OfflineSegment.waiting;
        }
        // Every file in the section, not only the wanted ones, must be maintained for it to read as library.
        return held & ~maintained == 0 ? OfflineSegment.done : OfflineSegment.spare;
      }
      return held != 0 ? OfflineSegment.spare : OfflineSegment.empty;
    }

    final thumbnail = OfflineVariant.thumbnail.bit;
    final preview = OfflineVariant.preview.bit;
    final full = OfflineVariant.original.bit | OfflineVariant.video.bit;
    return (
      thumbnail: segment(
        all: thumbnail,
        wanted: fetching.isWanted ? thumbnail : 0,
        maintained: maintaining.isWanted ? thumbnail : 0,
      ),
      preview: segment(
        all: preview,
        wanted: fetching.keepsPreview ? preview : 0,
        maintained: maintaining.keepsPreview ? preview : 0,
      ),
      full: segment(
        all: full,
        wanted: fullFiles(fetching, capped: fetchCapped),
        maintained: fullFiles(maintaining, capped: maintainCapped),
      ),
    );
  }

  int wantedFilesOf(String assetId) {
    final entry = _entries[assetId];
    return entry == null ? 0 : _filesFor(entry.quality, entry.isImage, entry.hasMotion);
  }

  void setWanted(
    String assetId,
    OfflineQuality quality, {
    required bool isImage,
    bool hasMotion = false,
    bool onDemand = false,
  }) {
    final existing = _entries[assetId];
    _restate();

    if (!quality.isWanted && (existing == null || existing.held == 0)) {
      _entries.remove(assetId);
      return;
    }

    if (existing == null) {
      _entries[assetId] = _Entry(quality, isImage, hasMotion, 0, 0, 0, 0, onDemand: onDemand);
      return;
    }
    existing
      ..quality = quality
      ..isImage = isImage
      ..hasMotion = hasMotion
      ..onDemand = onDemand;
  }

  bool holds(String assetId, OfflineVariant variant, int token) {
    final entry = _entries[assetId];
    if (entry == null || entry.held & variant.bit == 0) {
      return false;
    }
    return switch (variant) {
      OfflineVariant.thumbnail || OfflineVariant.preview => entry.token == token,
      // An edit renames the original too, so the bit alone is not enough.
      OfflineVariant.original => entry.originalToken == token,
      OfflineVariant.video => entry.videoToken == token,
    };
  }

  /// Recording a name already held is a rewrite, not an addition: the image path, a download and the queue may each
  /// record the same file. [sample] is off when replaying files already learned from.
  void markHeld(String assetId, OfflineVariant variant, int token, int size, {bool sample = true}) {
    final added = !holds(assetId, variant, token);
    if (added) {
      _storeBytes += size;
    }
    if (added && sample) {
      _variantFiles[variant.index]++;
      _variantBytes[variant.index] += size;
      final known = _entries[assetId];
      final source = known == null ? 0 : (known.isImage ? known.motionBytes : known.originalBytes);
      if (variant == OfflineVariant.video && source > 0) {
        _videoSample = (
          files: _videoSample.files + 1,
          stored: _videoSample.stored + size,
          originals: _videoSample.originals + source,
        );
      }
    }
    _restate();

    // A download that lands after its decision was reverted still counts as stored, just not as progress.
    final entry = _entries[assetId] ??= _Entry(OfflineQuality.none, variant != OfflineVariant.video, false, 0, 0, 0, 0);

    // A new token means the file under the old name shows the previous version, so those bits go first. Thumbnail and
    // preview share one token; original and video have one each.
    final superseded = switch (variant) {
      OfflineVariant.thumbnail ||
      OfflineVariant.preview => entry.token == token ? 0 : OfflineVariant.thumbnail.bit | OfflineVariant.preview.bit,
      OfflineVariant.original => entry.originalToken == token ? 0 : OfflineVariant.original.bit,
      // Changing the video form renames every video.
      OfflineVariant.video => entry.videoToken == token ? 0 : OfflineVariant.video.bit,
    };

    if (superseded != 0) {
      entry.held &= ~superseded;
      switch (variant) {
        case OfflineVariant.thumbnail || OfflineVariant.preview:
          entry.token = token;
        case OfflineVariant.original:
          entry.originalToken = token;
        case OfflineVariant.video:
          entry.videoToken = token;
      }
    }

    // Once per file: the same name can be recorded twice.
    if (entry.held & variant.bit == 0) {
      entry.held |= variant.bit;
    }
  }

  /// Stops counting files a newer version replaced. [markHeld] already moved their bits to the new version.
  void dropSupersededBytes(int size) {
    _storeBytes = _storeBytes > size ? _storeBytes - size : 0;
    _restate();
  }

  void dropHeld(String assetId, OfflineVariant variant, int size) {
    _storeBytes = _storeBytes > size ? _storeBytes - size : 0;
    _restate();
    final entry = _entries[assetId];
    if (entry == null) {
      return;
    }
    entry.held &= ~variant.bit;
    if (entry.held == 0 && !entry.quality.isWanted) {
      _entries.remove(assetId);
    }
  }

  /// Forgets everything, for an abandoned mirror. [clearHeld] keeps the decisions.
  void clear() {
    _entries.clear();
    _storeBytes = 0;
    _restate();
  }

  void clearHeld() {
    _entries.removeWhere((_, entry) => !entry.quality.isWanted);
    for (final entry in _entries.values) {
      entry.held = 0;
    }
    _storeBytes = 0;
    _restate();
  }

  /// The best complete level on disk: what still works if the network goes away.
  OfflineAvailability availabilityOf(String assetId) {
    final entry = _entries[assetId];
    if (entry == null) {
      return OfflineAvailability.none;
    }

    // The thumbnail is the floor: without it the item cannot draw in the grid.
    if (entry.held & OfflineVariant.thumbnail.bit == 0) {
      return OfflineAvailability.none;
    }
    if (entry.held & OfflineVariant.preview.bit == 0) {
      return OfflineAvailability.thumbnail;
    }

    final complete = entry.isImage ? OfflineVariant.original.bit : OfflineVariant.video.bit;
    return entry.held & complete != 0 ? OfflineAvailability.full : OfflineAvailability.preview;
  }
}
