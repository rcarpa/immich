/// immich-sync fork — what is wanted and what is here, in memory (FORK.md §3.4.1). Loaded once and maintained by the
/// events that change the store, because two callers need the answer with no I/O to wait for: the thumbnail badge, once
/// per visible tile per frame, and the reconciler, once per file.
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
  bool isImage;

  /// Whether the camera roll holds a usable original. Not part of a decision — it describes the device — so nothing that
  /// records a decision may overwrite it.
  bool localCopy;

  /// Whether *Save offline* is still outstanding, which overrides [localCopy].
  bool errand;

  /// Whether this row exists only because the item was fetched by hand. Every file of such an item is a spare, exactly
  /// as `_unselectedOver` reads it.
  bool onDemand;

  /// A Live Photo: its motion part is a fourth file, wanted at the top rung.
  bool hasMotion;

  /// Bitmask of the [OfflineVariant]s on disk.
  int held;

  /// Which generation is stored, so a superseded copy reads as missing.
  int token;
  int originalToken;
  int videoToken;
}

class OfflineIndex {
  final Map<String, _Entry> _entries = {};

  static OfflineIndex? _live;

  /// Availability without a `ref`, for upstream's plain `ImageProvider`s, which reach `SettingsRepository.instance` the
  /// same way.
  static OfflineAvailability availability(String assetId) => _live?.availabilityOf(assetId) ?? OfflineAvailability.none;

  /// Called once the service owning this index exists.
  void publish() => _live = this;

  /// The four figures the status line is built from, counted from the entries rather than adjusted alongside them.
  ///
  /// They used to be maintained by hand: every path that recorded a decision or a file added and subtracted its own
  /// share, in nine places, and each of those was a chance for the total to part company with the rows it claims to
  /// describe. Nothing here can drift now, because there is nothing to keep in step — a mutation marks the tally stale
  /// and the next reader counts. That costs one pass over the entries, at most once per burst, because every caller of
  /// these is behind the coalescing emit in `offline_sync.service.dart`.
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

  void _restate() => _tally = null;

  int get wantedAssets => _counts.wantedAssets;

  /// Files the current selection implies, so progress is exact without anything being listed.
  int get wantedFiles => _counts.wantedFiles;

  /// Files counting towards progress, and the bytes the store occupies.
  int get heldFiles => _counts.heldFiles;
  int get heldBytes => _storeBytes;

  /// How many variants of one entry are on disk.
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
    // A thumbnail at every rung, and a preview at every rung above the lowest, for a photo and a video alike — a video's
    // still is what its tile draws.
    if (!quality.keepsPreview) {
      return 1;
    }
    final big = isImage ? quality.keepsOriginal : quality.videoTier != OfflineVideoTier.none;
    // And a Live Photo's motion part on top of its original, which is the one item that implies four files.
    final motion = isImage && hasMotion && quality.videoTier != OfflineVideoTier.none;
    return (big ? 3 : 2) + (motion ? 1 : 0);
  }

  void load(List<OfflineIndexRow> rows, {required int heldBytes}) {
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
    // The store's own total, which is every file on disk and not only the ones a selection counts towards progress.
    _storeBytes = heldBytes;
  }

  /// Bytes on disk, including files no entry counts towards progress.
  int _storeBytes = 0;

  // --------------------------------------------------------------------------- Wants

  OfflineQuality wantedOf(String assetId) => _entries[assetId]?.quality ?? OfflineQuality.none;

  /// Whether the camera roll holds a usable original, so the mirror wants nothing beyond the preview (§3.2).
  ///
  /// The badge asks this rather than the asset it is drawing: `BaseAsset.hasLocal` is `localId != null`, and only some of
  /// upstream's timeline queries populate that column, so on the others it reads false for a photo the phone has — which
  /// drew a full-length track over every deduplicated item on those screens.
  bool localCopyOf(String assetId) => _entries[assetId]?.localCopy ?? false;

  /// Records what a pass read from upstream. Kept apart from [setWanted]: this describes the device, not a decision, and
  /// a re-derivation must not reset it.
  void noteLocalCopy(String assetId, {required bool localCopy}) {
    final entry = _entries[assetId];
    if (entry != null) {
      entry.localCopy = localCopy;
    }
  }

  /// Whether *Save offline* is still outstanding, which is what makes the target the whole item however much of it the
  /// camera roll holds — the same override `filesFor` applies.
  bool errandOf(String assetId) => _entries[assetId]?.errand ?? false;

  void noteErrand(String assetId, {required bool errand}) {
    final entry = _entries[assetId];
    if (entry != null) {
      entry.errand = errand;
    }
  }

  /// The three sections a tile's bar is drawn from (FORK.md §3.6): thumbnail, preview and full copy, each decided on
  /// its own from the files it covers.
  ///
  /// Two rungs, because they answer two questions, and each is the *same rule* another part of the mirror applies — a
  /// second copy of a rule is a second answer waiting to happen:
  ///
  /// - what is being **fetched** is what `filesFor` asks for: the rung, capped by the camera roll, and uncapped again by
  ///   an outstanding errand, which also takes the top rung;
  /// - what is **maintained** is what `_unselectedOver` counts as *not* a spare: the same without the errand, and
  ///   nothing at all for a row that exists only because the item was fetched by hand.
  ///
  /// A section is *waiting* while anything it is fetching is missing, *done* once all of it is here and maintained, and
  /// *spare* when it is here and something in it is not maintained — or when it holds files nothing is fetching.
  OfflineBar barOf(String assetId) {
    final entry = _entries[assetId];
    if (entry == null) {
      return kOfflineBarEmpty;
    }

    final fetching = entry.errand ? kOfflineErrandQuality : entry.quality;
    final maintaining = entry.onDemand ? OfflineQuality.none : entry.quality;
    // The camera roll caps what the mirror fetches of the expensive half, unless an errand asked for this app's own copy;
    // it caps what a setting maintains regardless, since the mirror never maintains a second copy (§3.2).
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
        // Everything here, the wanted files and any others in the section — a Live Photo's motion clip left by a higher
        // rung, say — has to be maintained for the section to read as library.
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

  /// How many files one item's selection implies — what it contributes to [wantedFiles], and therefore what has to come
  /// back out of the total when upstream turns out to have nothing to give for it.
  int wantedFilesOf(String assetId) {
    final entry = _entries[assetId];
    return entry == null ? 0 : _filesFor(entry.quality, entry.isImage, entry.hasMotion);
  }

  /// Records a decision, keeping what is known about the files either way.
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
      // Nothing wanted and nothing stored: there is no fact left to remember.
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

  // --------------------------------------------------------------------------- Files

  /// Whether the file for [variant] is on disk *and* still current.
  bool holds(String assetId, OfflineVariant variant, int token) {
    final entry = _entries[assetId];
    if (entry == null || entry.held & variant.bit == 0) {
      return false;
    }
    return switch (variant) {
      OfflineVariant.thumbnail || OfflineVariant.preview => entry.token == token,
      // Not `true`: an edit moves the original's name too (see `offlineOriginalUrl`), and vouching for the bit alone
      // would leave the full-size copy stuck on the pre-edit picture for good.
      OfflineVariant.original => entry.originalToken == token,
      OfflineVariant.video => entry.videoToken == token,
    };
  }

  /// A file already held under the same name is a rewrite, not an addition: the image path, a download and the queue
  /// claiming a file off disk can each record the same blob, in any order, and counting more than one would report
  /// bytes the device does not hold. Whichever records it first counts it, because until then it is in no total.
  void markHeld(String assetId, OfflineVariant variant, int token, int size) {
    if (!holds(assetId, variant, token)) {
      _storeBytes += size;
    }
    _restate();

    // A download that landed after its decision was reverted is still recorded: the bytes are on the device and will
    // serve the next reader, but they are not progress towards anything.
    final entry = _entries[assetId] ??= _Entry(OfflineQuality.none, variant != OfflineVariant.video, false, 0, 0, 0, 0);

    // Which bits this generation invalidates: a token that has moved means what is on disk under the old name is a
    // picture of the previous version, so those files stop counting before the new one is added. The thumbnail and the
    // preview share one token — upstream's cache buster — so an edit supersedes the pair; the original and the video
    // carry one each (§3.4).
    final superseded = switch (variant) {
      OfflineVariant.thumbnail ||
      OfflineVariant.preview => entry.token == token ? 0 : OfflineVariant.thumbnail.bit | OfflineVariant.preview.bit,
      OfflineVariant.original => entry.originalToken == token ? 0 : OfflineVariant.original.bit,
      // Not left out: flipping `loadOriginalVideo` renames every video at once, and vouching for the bit alone counted
      // both generations.
      OfflineVariant.video => entry.videoToken == token ? 0 : OfflineVariant.video.bit,
    };

    if (superseded != 0) {
      // The bits go, and the tally follows on its own: a superseded file stops counting because it stops being held,
      // not because something remembered to subtract it.
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

    // Counted once per file, not once per call: the same name can be marked twice — a task the plugin reports a final
    // state for after the queue already claimed the file off disk — and counting both let progress read complete over a
    // store that was not.
    if (entry.held & variant.bit == 0) {
      entry.held |= variant.bit;
    }
  }

  /// The store's byte total moves here; whether this file counted towards progress is a question the tally answers for
  /// itself, from the entry it has just changed.
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

  /// Forgets everything, for a mirror abandoned rather than emptied.
  ///
  /// Distinct from [clearHeld], which deliberately keeps the decisions: there the files are gone and the selection
  /// stands, so the counts have to go on describing what is still wanted.
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

  // --------------------------------------------------------------------------- The badge

  /// The best *complete* level on disk — what happens if the network goes away, so it describes the files and not the
  /// decision.
  OfflineAvailability availabilityOf(String assetId) {
    final entry = _entries[assetId];
    if (entry == null) {
      return OfflineAvailability.none;
    }

    // The thumbnail is the floor: without it the item cannot even draw in the grid. With it and nothing more, it draws
    // there and opens to that same small picture, which is all the lowest rung asks for.
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
