/// immich-sync fork — what is wanted and what is here, in memory (FORK.md §3.4.1). Loaded once and maintained by the
/// events that change the store, because two callers need the answer with no I/O to wait for: the thumbnail badge, once
/// per visible tile per frame, and the reconciler, once per file.
library;

import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/infrastructure/repositories/offline_flags.repository.dart';
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
  static OfflineAvailability availability(String assetId) =>
      _live?.availabilityOf(assetId) ?? OfflineAvailability.none;

  /// Called once the service owning this index exists.
  void publish() => _live = this;

  int _wantedAssets = 0;
  int _wantedFiles = 0;
  int _heldFiles = 0;
  int _heldBytes = 0;

  int get wantedAssets => _wantedAssets;

  /// Files the current selection implies, so progress is exact without anything being listed.
  int get wantedFiles => _wantedFiles;

  /// Files counting towards progress, and the bytes the store occupies.
  int get heldFiles => _heldFiles;
  int get heldBytes => _heldBytes;

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
    // A thumbnail and a preview at every rung, for a photo and a video alike — a video's still is what its tile draws.
    final big = isImage ? quality.keepsOriginal : quality.videoTier != OfflineVideoTier.none;
    // And a Live Photo's motion part on top of its original, which is the one item that implies four files.
    final motion = isImage && hasMotion && quality.videoTier != OfflineVideoTier.none;
    return (big ? 3 : 2) + (motion ? 1 : 0);
  }

  void load(List<OfflineIndexRow> rows, {required int heldFiles, required int heldBytes}) {
    _entries.clear();
    _wantedAssets = 0;
    _wantedFiles = 0;
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
      if (row.quality.isWanted) {
        _wantedAssets++;
        _wantedFiles += _filesFor(row.quality, row.isImage, row.hasMotion);
      }
    }
    _heldFiles = heldFiles;
    _heldBytes = heldBytes;
  }

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

  /// The three figures a tile's bar is drawn from (FORK.md §3.6).
  ///
  /// Here rather than in the widget because two of them are the *same rules* the download side and the reclaim bands
  /// apply, and a second copy of a rule is a second answer waiting to happen:
  ///
  /// - [OfflineBar.target] is what `filesFor` asks for — the rung, capped by the camera roll, uncapped again by an
  ///   outstanding errand;
  /// - [OfflineBar.maintained] is what `_unselectedOver` counts as *not* a spare — the same, without the errand, and
  ///   nothing at all for a row that exists only because the item was fetched by hand.
  ///
  /// Keeping them apart is what the bar is for. An errand widens what is being fetched without changing what any setting
  /// maintains, so folding it into both draws the incoming copy as library and then a cleanup takes it anyway.
  OfflineBar barOf(String assetId) {
    final entry = _entries[assetId];
    if (entry == null) {
      return (maintained: 0.0, target: 0.0, stored: 0.0);
    }

    // Two rungs, because an errand overrides the recorded one — the same substitution `filesFor` makes, and for the same
    // reason: the row's `quality` is what the *selection* maintains, so it must not be widened to describe a request
    // for one item.
    final maintainedRung = entry.quality;
    final fetchingRung = entry.errand ? kOfflineErrandQuality : entry.quality;

    bool wantsBig(OfflineQuality rung) =>
        entry.isImage ? rung.keepsOriginal : rung.videoTier != OfflineVideoTier.none;
    double level(OfflineQuality rung, {required bool big}) => !rung.isWanted ? 0.0 : (big ? 1.0 : 0.5);

    // Per file, and deliberately finer than [availabilityOf]. That one is coarse on purpose — it answers "what can this
    // show with no network", and a thumbnail on its own shows nothing — but a *progress* bar has the opposite job. The
    // queue fetches every thumbnail in the library before any preview (§3.3), so a bar built on availability sits at
    // empty for as long as that takes while the screen's own counter climbs, which is the one thing it must not do.
    //
    // A quarter each for the thumbnail and the preview, so the two of them make up the ½ the preview pair is worth on
    // this scale, and a half for the full-size file. Summed rather than staged: a preview that arrives before its
    // thumbnail counts for what it is instead of waiting.
    double heldWeight(int bit, double weight) => entry.held & bit == 0 ? 0.0 : weight;
    final bigBit = entry.isImage ? OfflineVariant.original.bit : OfflineVariant.video.bit;

    return (
      maintained: entry.onDemand
          ? 0.0
          : level(maintainedRung, big: wantsBig(maintainedRung) && !entry.localCopy),
      target: level(fetchingRung, big: wantsBig(fetchingRung) && (entry.errand || !entry.localCopy)),
      stored:
          heldWeight(OfflineVariant.thumbnail.bit, 0.25) +
          heldWeight(OfflineVariant.preview.bit, 0.25) +
          heldWeight(bigBit, 0.5),
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
    if (existing != null && existing.quality.isWanted) {
      _wantedAssets--;
      _wantedFiles -= _filesFor(existing.quality, existing.isImage, existing.hasMotion);
      _heldFiles -= _heldCount(existing.held);
    }

    if (quality.isWanted) {
      _wantedAssets++;
      _wantedFiles += _filesFor(quality, isImage, hasMotion);
      _heldFiles += _heldCount(existing?.held ?? 0);
    } else if (existing == null || existing.held == 0) {
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

  /// [isNewToStore] is false for a file the store already held and is only now claiming back for a selection, whose
  /// bytes are already in the total.
  void markHeld(String assetId, OfflineVariant variant, int token, int size, {bool isNewToStore = true}) {
    if (isNewToStore) {
      _heldBytes += size;
    }

    // A download that landed after its decision was reverted is still recorded: the bytes are on the device and will
    // serve the next reader, but they are not progress towards anything.
    final entry = _entries[assetId] ??= _Entry(OfflineQuality.none, variant != OfflineVariant.video, false, 0, 0, 0, 0);

    // Which bits this generation invalidates: a token that has moved means what is on disk under the old name is a
    // picture of the previous version, so those files stop counting before the new one is added. The thumbnail and the
    // preview share one token — upstream's cache buster — so an edit supersedes the pair; the original and the video
    // carry one each (§3.4).
    final superseded = switch (variant) {
      OfflineVariant.thumbnail || OfflineVariant.preview =>
        entry.token == token ? 0 : OfflineVariant.thumbnail.bit | OfflineVariant.preview.bit,
      OfflineVariant.original => entry.originalToken == token ? 0 : OfflineVariant.original.bit,
      // Not left out: flipping `loadOriginalVideo` renames every video at once, and vouching for the bit alone counted
      // both generations.
      OfflineVariant.video => entry.videoToken == token ? 0 : OfflineVariant.video.bit,
    };

    if (superseded != 0) {
      for (final stale in OfflineVariant.values) {
        if (superseded & stale.bit != 0 && entry.held & stale.bit != 0 && entry.quality.isWanted) {
          _heldFiles = _heldFiles > 0 ? _heldFiles - 1 : 0;
        }
      }
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
      if (entry.quality.isWanted) {
        _heldFiles++;
      }
      entry.held |= variant.bit;
    }
  }

  /// Bytes always, files only when this one counted towards progress — the filter [setWanted] and
  /// [OfflineFlagsRepository.heldTotals] also apply.
  void dropHeld(String assetId, OfflineVariant variant, int size) {
    _heldBytes = _heldBytes > size ? _heldBytes - size : 0;
    final entry = _entries[assetId];
    if (entry == null) {
      return;
    }
    if (entry.quality.isWanted && entry.held & variant.bit != 0) {
      _heldFiles = _heldFiles > 0 ? _heldFiles - 1 : 0;
    }
    entry.held &= ~variant.bit;
    if (entry.held == 0 && !entry.quality.isWanted) {
      _entries.remove(assetId);
    }
  }

  void clearHeld() {
    _entries.removeWhere((_, entry) => !entry.quality.isWanted);
    for (final entry in _entries.values) {
      entry.held = 0;
    }
    _heldFiles = 0;
    _heldBytes = 0;
  }

  // --------------------------------------------------------------------------- The badge

  /// The best *complete* level on disk — what happens if the network goes away, so it describes the files and not the
  /// decision.
  OfflineAvailability availabilityOf(String assetId) {
    final entry = _entries[assetId];
    if (entry == null) {
      return OfflineAvailability.none;
    }

    final base = OfflineVariant.thumbnail.bit | OfflineVariant.preview.bit;
    if (entry.held & base != base) {
      return OfflineAvailability.none;
    }

    final complete = entry.isImage ? OfflineVariant.original.bit : OfflineVariant.video.bit;
    return entry.held & complete != 0 ? OfflineAvailability.full : OfflineAvailability.preview;
  }
}
