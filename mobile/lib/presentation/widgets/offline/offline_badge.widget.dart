/// immich-sync fork — what a tile says about a photo, in one mark (FORK.md §3.6).
///
/// Upstream drew a single cloud describing *where the bytes are*: `cloud_off` on the phone only, `cloud` on the server
/// only, `cloud_done` on both. That glyph is kept exactly as it was — a rebase that changes it changes this too — and the
/// mirror adds its own axis under it as a progress bar, not beside it as a second glyph.
///
/// Three figures on one scale, where 1 is everything the photo needs to open at full quality and ½ is the preview pair
/// alone (`OfflineIndex.barOf`): what a setting **maintains**, what the mirror is **fetching**, and what the store
/// **holds**. Three and not two, because each pair of them answers a different question and collapsing any pair loses
/// something the user acts on.
///
/// - **the track** — a dark plate — runs to the longest of the three, so a copy no setting asked for still has room to
///   be seen;
/// - **solid white** runs to where a setting maintains what is here;
/// - **amber, after a gap**, on to what is here: a spare, which nothing re-downloads and any cleanup may take;
/// - **bare plate**, on to what is coming: still to arrive.
///
/// **What is held is measured per file**, so the preview pair's ½ is a quarter for the thumbnail and a quarter for the
/// preview. That is finer than `availabilityOf`, which is coarse on purpose, and it has to be: the queue fetches every
/// thumbnail in the library before any preview (§3.3), so a bar that only moved when an item became *openable* would
/// stand still for as long as that takes while the offline screen's own counter climbed.
///
/// | maintains | fetching | holds | bar                                                              |
/// | ½         | ½        | 0     | half plate, bare — nothing here yet                             |
/// | ½         | ½        | ¼     | half plate, half white — the thumbnail landed, the preview is next |
/// | ½         | ½        | ½     | half track, white — as complete as this one gets                 |
/// | ½         | 1        | ½     | full plate: white half then bare — a spare is on its way        |
/// | ½         | ½ or 1   | 1     | full track: white half, gap, amber half — the rest is a spare    |
/// | 1         | 1        | ½     | full plate: white half then bare — the full-size file is to come  |
/// | 0         | 1        | ½     | full plate: amber half then bare — none of it is maintained       |
/// | 0         | 0        | ½ / 1 | track to what is held, all amber — nothing maintains any of it   |
///
/// A half-length *maintains* means no setting asks for more than the preview, for one of two reasons that look the same
/// because their consequence is: the rung asks for no more, or the camera roll already holds the original and fetching it
/// would store the photo twice (§3.2). **Fetching** differs from it only for an errand, which asks for this app's own
/// copy regardless — so the track lengthens while the white does not, and what lands is amber.
library;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';

/// The size upstream's own tile overlays use.
const double _kMarkSize = 16.0;

/// A hairline: the track's length and how much of it is filled carry the meaning, so the thickness only has to make
/// them visible.
const double _kMeterHeight = 1.0;

/// The dark plate the bar is drawn on, and the only thing that makes a hairline legible.
///
/// A shadow cannot do it. `BoxShadow` blurs the *shape* it sits behind, and a one-pixel-tall shape blurred over five
/// pixels has almost no peak opacity left — the glyph above gets away with the same shadow because it is sixteen pixels
/// of real strokes. A white line on a white photograph was invisible, and so was the faint-white segment that used to
/// mean "still to come".
///
/// So the plate is opaque enough to read on white, and it doubles as that segment: **what is still to come is the plate
/// showing through**, which needs no colour of its own and works on a bright photograph and a dark one alike.
const double _kMeterPlate = 3.0;
const Color _kPlateColor = Color.fromRGBO(0, 0, 0, 0.45);

/// The halo the glyph wears, as upstream's own tile icons do, so white survives a bright photograph.
///
/// The bar cannot use it: a shadow blurs the shape behind it, and a one-pixel-tall shape has nothing left to blur. It
/// gets a plate instead (see [_kMeterPlate]).
const Color _kHaloColor = Color.fromRGBO(0, 0, 0, 0.6);
const double _kHaloBlur = 5.0;

/// What the mirror maintains: white, like the glyph.
const Color _kMaintainedColor = Colors.white;

/// A spare — held, but maintained by nothing. The icon's own accent, and deliberately not a dimmer white.
///
/// Brightness is already spoken for: a dim segment is what "not downloaded yet" looks like, and telling 0.6 alpha from
/// 0.4 alpha across two tiles of a scrolling grid, one pixel tall, over photographs, is not something anyone can do. A
/// spare is a different *kind* of thing rather than less of the same thing, so it gets a different channel — hue, plus
/// the gap that detaches it (see [_meter]). Two independent signals, either of which is enough on its own.
const Color _kSpareColor = Color(0xFFFFB020);

/// The break between what is maintained and what is spare, so the two never touch.
///
/// Half of it comes out of each side. Taking the whole gap from one segment shortens that segment by the gap and leaves
/// the break off-centre, which reads as two unequal parts rather than one bar divided.
const double _kSpareGap = 2.0;

/// How far the bar is inset from each side of the mark, leaving it a little narrower than the cloud above it.
const double _kMeterInset = 2.0;

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
    final bar = remoteId == null
        ? (maintained: 0.0, target: 0.0, stored: 0.0)
        : ref.watch(offlineSyncServiceProvider).barOf(remoteId);

    // What the *mirror* holds, which is a different question from where the bytes are: a photo can be on the phone and
    // on the server with nothing in the offline store, and a photo can be gone from the phone with the store holding all
    // of it. Nothing wanted, nothing coming and nothing stored is nothing to draw.
    if (bar.target == 0 && bar.stored == 0) {
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

  /// The bar in words, for a screen reader — which cannot see a length, so it gets every part of it spelled out.
  String _storeLabel(OfflineBar bar) {
    final still = asset.isVideo ? 'a still' : 'a preview';
    final big = asset.isVideo ? 'the video' : 'the full-size photo';

    return [
      // What it can show off-grid right now, on the same ½-is-the-preview-pair scale the bar is drawn on.
      if (bar.stored >= 1.0)
        'Kept offline at full quality'
      else if (bar.stored >= 0.5)
        'Kept offline as $still'
      else if (bar.stored > 0)
        'Part downloaded'
      else
        'Nothing downloaded yet',
      // Held beyond what any setting maintains: nothing re-downloads it and a cleanup may take it.
      if (bar.stored > bar.maintained) 'the rest is a spare',
      if (bar.stored < bar.target) bar.stored < 0.5 ? '$still still to come' : '$big still to come',
    ].join(', ');
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

/// The progress bar: a track as long as the target, filled by how much of it is here.
///
/// The track is drawn in white at low opacity rather than in black, and carries the same halo as the glyph, so both ends
/// of it read on a bright photograph and on a dark one. A black track was invisible on white — which is most of the
/// interesting photos — and an empty one then said nothing at all.
///
/// Both layers are `Positioned.fill` rather than plain children: a non-positioned child of a `Stack` gets *loose*
/// constraints, and `FractionallySizedBox` then sizes itself to its child instead of to the track — leaving its
/// alignment nothing to align within, so a centred track drew exactly like a full-width one.
Widget _meter(OfflineBar bar) {
  // The longest of the three, so a copy no setting asked for still gets a bar long enough to show it. A photo whose
  // original is in the camera roll wants only a preview; hand-saving it anyway is a full copy on the device, and a
  // half-length bar would report that as "as complete as this gets" when the store holds twice that.
  final track = [bar.maintained, bar.target, bar.stored].reduce((a, b) => a > b ? a : b);

  // Three bands along that plate, in order: solid to where a setting maintains what is here, amber on to what is here,
  // bare plate on to what is still coming. All three can occur at once — an item nothing selects, half fetched by hand,
  // is maintained 0, stored ½, target 1 — so the amber has to stop at what is stored rather than run to the end.
  final maintained = bar.maintained < bar.stored ? bar.maintained : bar.stored;
  final spare = bar.stored - maintained;
  final pending = track - bar.stored;

  // Flex rather than nested fractions, so the gap can be real pixels between two shares of what is left. That is also
  // what keeps the break centred and the two segments equal: the gap is taken out of the row before the shares are
  // divided, not out of one of them.
  int share(double part) => (part * 1000).round();

  return SizedBox(
    height: _kMeterPlate,
    child: FractionallySizedBox(
      // A short plate is centred under the glyph: it is a state, not a bar that has stopped part way.
      widthFactor: track,
      alignment: Alignment.center,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: _kPlateColor,
                borderRadius: BorderRadius.all(Radius.circular(_kMeterPlate)),
              ),
            ),
          ),
          Positioned.fill(
            child: Row(
              // Each segment is given the plate's full height and insets itself to the hairline, which is what keeps the
              // width constraints tight all the way down — a `Center` here would leave the row's children unbounded.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (maintained > 0) Expanded(flex: share(maintained), child: _bar(_kMaintainedColor)),
                if (maintained > 0 && spare > 0) const SizedBox(width: _kSpareGap),
                if (spare > 0) Expanded(flex: share(spare), child: _bar(_kSpareColor)),
                // Nothing drawn: the plate showing through is what "still to come" looks like, and it reads on a bright
                // photograph where a faint white line does not.
                if (pending > 0) Spacer(flex: share(pending)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// One segment: the hairline, centred on the plate by insetting the height it was given.
Widget _bar(Color color) => Padding(
  padding: const EdgeInsets.symmetric(vertical: (_kMeterPlate - _kMeterHeight) / 2),
  child: DecoratedBox(
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(_kMeterHeight)),
  ),
);
