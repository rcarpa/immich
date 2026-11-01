/// immich-sync fork: what a tile says about a photo. Upstream's cloud glyph (where the bytes are) is kept as is, and
/// the mirror draws a bar under it with three fixed sections: thumbnail, preview and full copy (`OfflineIndex.barOf`).
///
/// | state   | when                                       | drawn as             |
/// | empty   | not wanted, not here                       | nothing              |
/// | waiting | wanted, not here yet                       | the dark plate, bare |
/// | done    | here, and a setting maintains it           | white on the plate   |
/// | spare   | here, and nothing maintains it             | amber on the plate   |
///
/// The sections are 2, 4 and 6 pixels with a pixel between each, 14 in all.
library;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';

/// The size upstream's own tile overlays use.
const double _kMarkSize = 16.0;

/// A hairline; the sections' colours carry the meaning.
const double _kMeterHeight = 1.0;

/// The dark plate under each wanted or held section. It makes the hairline legible on a white photo, where a shadow on
/// a one-pixel line does not, and on its own it is the waiting state.
const double _kMeterPlate = 3.0;
const Color _kPlateColor = Color.fromRGBO(0, 0, 0, 0.45);

/// The halo the glyph wears, as upstream's own tile icons do, so white survives a bright photograph.
const Color _kHaloColor = Color.fromRGBO(0, 0, 0, 0.6);
const double _kHaloBlur = 5.0;

const Color _kMaintainedColor = Colors.white;

/// A spare, held but not maintained. The icon's accent colour.
const Color _kSpareColor = Color(0xFFFFB020);

const double _kThumbnailWidth = 2.0;
const double _kPreviewWidth = 4.0;
const double _kFullWidth = 6.0;
const double _kSeparator = 1.0;

const double _kMeterInset = (_kMarkSize - (_kThumbnailWidth + _kPreviewWidth + _kFullWidth + 2 * _kSeparator)) / 2;

class OfflineAvailabilityIndicator extends ConsumerWidget {
  const OfflineAvailabilityIndicator({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (cloud, whereLabel) = switch ((asset.hasLocal, asset.hasRemote)) {
      (true, false) => (Icons.cloud_off_outlined, 'Not backed up yet'),
      (false, true) => (Icons.cloud_outlined, 'On the server'),
      _ => (Icons.cloud_done_outlined, 'Backed up'),
    };

    final remoteId = asset.remoteId;
    final service = ref.watch(offlineSyncServiceProvider);
    // From the mirror's index only. Not `asset.hasLocal`, which some timeline queries never populate. Selected, so a
    // revision rebuilds only the tiles whose bar it changed.
    final bar = remoteId == null
        ? kOfflineBarEmpty
        : ref.watch(offlineRevisionProvider.select((_) => service.barOf(remoteId)));

    // Nothing wanted, coming or stored: nothing to draw.
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
          // Just under the cloud, offset by the plate's overhang.
          Positioned(left: _kMeterInset, right: _kMeterInset, bottom: -_kMeterPlate + 1, child: meter),
      ],
    ),
  );

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

/// A white glyph with the halo upstream's `_TileOverlayIcon` uses, via [Icon.shadows] so it follows the glyph.
Icon _mark(IconData icon, double size) => Icon(
  icon,
  color: Colors.white,
  size: size,
  shadows: const [Shadow(blurRadius: _kHaloBlur, color: _kHaloColor, offset: Offset.zero)],
);

/// The bar: three fixed sections with a separator between each. Only their colours change.
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

/// One section: nothing when empty, the bare plate while waiting, then a white (maintained) or amber (spare) line.
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

@visibleForTesting
Widget offlineMeterForTesting(OfflineBar bar) => _meter(bar);
