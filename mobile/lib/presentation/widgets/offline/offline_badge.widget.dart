/// immich-sync fork — what a tile says about a photo, in one mark (FORK.md §3.6).
///
/// Upstream drew a single cloud describing *where the bytes are*: `cloud_off` on the phone only, `cloud` on the server
/// only, `cloud_done` on both. That glyph is kept exactly as it was — a rebase that changes it changes this too — and the
/// mirror adds its own axis under it as a progress bar, not beside it as a second glyph.
///
/// **Three sections, always in the same place**: the thumbnail, the preview and the full copy (`OfflineIndex.barOf`).
/// Each is decided on its own, and only its colour ever changes — nothing is centred, scaled or merged, so the same
/// state looks the same on every tile:
///
/// | state   | when                                                        | drawn as                 |
/// | empty   | not wanted, not on the device                               | nothing                  |
/// | waiting | wanted — by a setting or by *Save offline* — not here yet   | the dark plate, bare     |
/// | done    | here, and a setting maintains it                            | white on the plate       |
/// | spare   | here, and nothing maintains it                              | amber on the plate       |
///
/// The sections are 2, 4 and 6 pixels with a pixel between each — 14 in all, the glyph inset a pixel each side. 1 : 2
/// : 3 keeps the order the files cost in, and is the smallest split in whole pixels that leaves the thumbnail visible:
/// a quarter of a quarter would be a pixel, which disappears at arm's length. When every section is filled it reads as
/// one progress bar.
///
/// The full copy is a photo's original — with a Live Photo's motion clip where the rung asks for videos — or a video's
/// playable file. A section *waits* while anything it is fetching is missing. One the camera roll already holds is not
/// fetched, so it stays empty, unless *Save offline* fetched the app's own copy anyway, which is then a spare.
library;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';

/// The size upstream's own tile overlays use.
const double _kMarkSize = 16.0;

/// A hairline: which sections are filled, and in what colour, carry the meaning, so the thickness only has to make them
/// visible.
const double _kMeterHeight = 1.0;

/// The dark plate each wanted or held section is drawn on, and the only thing that makes a hairline legible.
///
/// A shadow cannot do it. `BoxShadow` blurs the *shape* it sits behind, and a one-pixel-tall shape blurred over five
/// pixels has almost no peak opacity left — the glyph above gets away with the same shadow because it is sixteen pixels
/// of real strokes. A white line on a white photograph was invisible, and so was the faint-white segment that used to
/// mean "still to come".
///
/// So the plate is opaque enough to read on white, and it doubles as the *waiting* state: **what is still to come is
/// the plate with nothing on it**, which needs no colour of its own and works on a bright photograph and a dark one.
const double _kMeterPlate = 3.0;
const Color _kPlateColor = Color.fromRGBO(0, 0, 0, 0.45);

/// The halo the glyph wears, as upstream's own tile icons do, so white survives a bright photograph.
const Color _kHaloColor = Color.fromRGBO(0, 0, 0, 0.6);
const double _kHaloBlur = 5.0;

/// What a setting maintains: white, like the glyph.
const Color _kMaintainedColor = Colors.white;

/// A spare — held, but maintained by nothing. The icon's own accent, and deliberately not a dimmer white: brightness is
/// already spoken for by the waiting plate, and a spare is a different *kind* of thing rather than less of the same.
const Color _kSpareColor = Color(0xFFFFB020);

/// The three sections' widths and the separator between them, in logical pixels. Fixed: a section never moves, grows or
/// shrinks, whatever the others say.
const double _kThumbnailWidth = 2.0;
const double _kPreviewWidth = 4.0;
const double _kFullWidth = 6.0;
const double _kSeparator = 1.0;

/// How far the bar is inset from each side of the mark: one pixel, which leaves exactly the 14 the sections add up to.
const double _kMeterInset = (_kMarkSize - (_kThumbnailWidth + _kPreviewWidth + _kFullWidth + 2 * _kSeparator)) / 2;

class OfflineAvailabilityIndicator extends ConsumerWidget {
  const OfflineAvailabilityIndicator({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Upstream's own three states, by where the bytes are.
    final (cloud, whereLabel) = switch ((asset.hasLocal, asset.hasRemote)) {
      (true, false) => (Icons.cloud_off_outlined, 'Not backed up yet'),
      (false, true) => (Icons.cloud_outlined, 'On the server'),
      _ => (Icons.cloud_done_outlined, 'Backed up'),
    };

    ref.watch(offlineRevisionProvider);
    final remoteId = asset.remoteId;
    // The mirror's own three figures, and no rule of this widget's own.
    //
    // In particular not `asset.hasLocal`, which is `localId != null` and therefore says as much about the query that
    // built this tile as about the device: `_getPlaceBucketAssets`, `_getMapBucketAssets` and `_getRemoteAssets` build
    // their rows with a plain `toDto()`, so on those screens it reads false for a photo the phone certainly has. Nor as a
    // hint alongside the index — taking either holds the stale answer after a local copy is deleted, since `localId ==
    // null` cannot be told apart from "this query does not populate it".
    final bar = remoteId == null ? kOfflineBarEmpty : ref.watch(offlineSyncServiceProvider).barOf(remoteId);

    // What the *mirror* holds, which is a different question from where the bytes are: a photo can be on the phone and
    // on the server with nothing in the offline store, and a photo can be gone from the phone with the store holding all
    // of it. Nothing wanted, nothing coming and nothing stored is nothing to draw.
    if (bar == kOfflineBarEmpty) {
      return Semantics(label: whereLabel, excludeSemantics: true, child: _cloud(cloud));
    }

    return Semantics(
      label: '$whereLabel · ${_storeLabel(bar)}',
      excludeSemantics: true,
      child: _cloud(cloud, meter: _meter(bar)),
    );
  }

  Widget _cloud(IconData icon, {Widget? meter}) => SizedBox(
    width: _kMarkSize,
    height: _kMarkSize,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        _mark(icon, _kMarkSize),
        if (meter != null)
          // Just under the cloud's bottom edge and a little narrower than it: read as part of the same mark, and clear
          // of every stroke in it.
          // Offset by the plate's own overhang, so the hairline itself sits exactly where a bare one-pixel bar would.
          Positioned(left: _kMeterInset, right: _kMeterInset, bottom: -_kMeterPlate + 1, child: meter),
      ],
    ),
  );

  /// The bar in words, for a screen reader — which cannot see a colour, so each section gets its state spelled out.
  String _storeLabel(OfflineBar bar) {
    final full = asset.isVideo ? 'video' : 'full-size photo';
    String say(String what, OfflineSegment segment) => switch (segment) {
      OfflineSegment.empty => '',
      OfflineSegment.waiting => '$what still to come',
      OfflineSegment.done => '$what kept offline',
      OfflineSegment.spare => '$what kept as a spare',
    };
    return [
      say('thumbnail', bar.thumbnail),
      say(asset.isVideo ? 'still' : 'preview', bar.preview),
      say(full, bar.full),
    ].where((part) => part.isNotEmpty).join(', ');
  }
}

/// A white glyph with the halo upstream's `_TileOverlayIcon` gives its own marks, so it survives a white photo. Shadowed
/// through [Icon.shadows], which follows the glyph, and not through a `BoxDecoration`, which would blur the rectangle
/// around it.
Icon _mark(IconData icon, double size) => Icon(
  icon,
  color: Colors.white,
  size: size,
  shadows: const [Shadow(blurRadius: _kHaloBlur, color: _kHaloColor, offset: Offset.zero)],
);

/// The bar: three fixed sections — thumbnail, preview, full copy — with a separator between each, left-aligned and never
/// moved. Only their colours change.
Widget _meter(OfflineBar bar) => SizedBox(
  height: _kMeterPlate,
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _section(bar.thumbnail, _kThumbnailWidth),
      const SizedBox(width: _kSeparator),
      _section(bar.preview, _kPreviewWidth),
      const SizedBox(width: _kSeparator),
      _section(bar.full, _kFullWidth),
    ],
  ),
);

/// One section: nothing when empty, the bare plate while waiting, and a hairline on the plate once it is here — white
/// when a setting maintains it, amber when nothing does.
Widget _section(OfflineSegment segment, double width) {
  final Color? line = switch (segment) {
    OfflineSegment.empty || OfflineSegment.waiting => null,
    OfflineSegment.done => _kMaintainedColor,
    OfflineSegment.spare => _kSpareColor,
  };
  return SizedBox(
    width: width,
    child: segment == OfflineSegment.empty
        ? null
        : DecoratedBox(
            decoration: const BoxDecoration(
              color: _kPlateColor,
              borderRadius: BorderRadius.all(Radius.circular(_kMeterHeight)),
            ),
            child: line == null
                ? null
                : Padding(
                    padding: const EdgeInsets.symmetric(vertical: (_kMeterPlate - _kMeterHeight) / 2),
                    child: ColoredBox(color: line),
                  ),
          ),
  );
}

/// The mark under the glyph on its own, for tests.
@visibleForTesting
Widget offlineMeterForTesting(OfflineBar bar) => _meter(bar);
