/// immich-sync fork — the controls that select what stays available offline. An album borrows upstream's
/// `BackupSelection.selected / none / excluded`.
library;

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';

/// `PopupMenuButton` treats a null result as "dismissed", so every option needs a non-null value of its own.
enum OfflineChoice {
  off,
  thumbnails,
  previews,
  full,
  fullWithVideos,
  excluded;

  static OfflineChoice ofQuality(OfflineQuality? quality) => switch (quality) {
    OfflineQuality.fullWithVideos => fullWithVideos,
    OfflineQuality.full => full,
    OfflineQuality.preview => previews,
    OfflineQuality.thumbnail => thumbnails,
    _ => off,
  };

  OfflineQuality? get quality => switch (this) {
    OfflineChoice.fullWithVideos => OfflineQuality.fullWithVideos,
    OfflineChoice.full => OfflineQuality.full,
    OfflineChoice.previews => OfflineQuality.preview,
    OfflineChoice.thumbnails => OfflineQuality.thumbnail,
    _ => null,
  };
}

/// A row whose trailing menu selects, and whose subtitle reports.
class OfflineSelectionRow extends StatelessWidget {
  const OfflineSelectionRow({
    super.key,
    required this.title,
    required this.value,
    required this.onSelected,
    required this.labels,
    this.icon,
    this.subtitle,
    this.footer,
    this.showState = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final OfflineChoice value;
  final ValueChanged<OfflineChoice> onSelected;

  /// The options this row offers, in order.
  final List<OfflineChoiceOption> labels;

  /// Under the subtitle, where a row reports what its own change left behind.
  final Widget? footer;

  /// Whether the row wears its own state as a mark and a tint.
  ///
  /// For a list of albums, where the point is to read fifty rows at a glance rather than the trailing label on each.
  /// Off elsewhere: the library row has no neighbours to be distinguished from, and the row on an album's own options
  /// page sits among upstream's other options, where one tinted line would read as something having gone wrong.
  final bool showState;

  String get _current => labels.firstWhere((option) => option.choice == value, orElse: () => labels.first).label;

  /// How a row shows its state, in upstream's own vocabulary (`album_info_list_tile.dart`): a check in the
  /// primary colour for something the settings keep, a minus in the error colour for something they refuse, a muted
  /// dot for one that simply follows the setting above. The same marks because it is the same question, asked of a
  /// different library — and only three of them for five rungs, because *which* rung is the trailing label's job.
  /// Drawing it twice would make a louder claim about a preview than the word "Previews" already does.
  ///
  /// The tints are upstream's hues at a lower alpha. Its rows are one or two lines and its excluded state is rare; a
  /// row here carries a subtitle and up to three notes under it, and excluding an album is an ordinary choice, so the
  /// same alpha covered half the screen in red and left the mark and the menu label short of contrast against it.
  ({IconData icon, Color foreground, Color tile}) _stateMark(BuildContext context) {
    final dark = context.isDarkTheme;
    return switch (value) {
      OfflineChoice.excluded => (
        icon: Icons.remove_circle_rounded,
        foreground: context.colorScheme.error,
        tile: (dark ? Colors.red[300]! : Colors.red[100]!).withAlpha(dark ? 60 : 120),
      ),
      OfflineChoice.off => (
        icon: Icons.circle,
        foreground: context.colorScheme.surfaceContainerHighest,
        tile: Colors.transparent,
      ),
      OfflineChoice.thumbnails || OfflineChoice.previews || OfflineChoice.full || OfflineChoice.fullWithVideos => (
        icon: Icons.check_circle_rounded,
        foreground: context.colorScheme.primary,
        tile: context.primaryColor.withAlpha(dark ? 60 : 25),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final mark = showState ? _stateMark(context) : null;
    final notes = footer;

    final tile = ListTile(
      leading: mark != null ? Icon(mark.icon, color: mark.foreground) : (icon == null ? null : Icon(icon)),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: PopupMenuButton<OfflineChoice>(
        initialValue: value,
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final option in labels)
            PopupMenuItem(
              value: option.choice,
              // Kept in the list rather than dropped when it cannot be picked: an option that comes and goes is one the
              // user has to rediscover, and its absence explains nothing. Disabled, with the reason under it.
              enabled: option.unavailable == null,
              child: option.unavailable == null
                  ? Text(option.label)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(option.label),
                        Text(
                          option.unavailable!,
                          style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
            ),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_current, style: context.textTheme.labelLarge?.copyWith(color: context.colorScheme.primary)),
            Icon(Icons.arrow_drop_down, color: context.colorScheme.primary),
          ],
        ),
      ),
    );

    if (notes == null && mark == null) {
      return tile;
    }
    // The notes go *under* the tile rather than inside its subtitle, and the tint wraps both. A `ListTile` sizes
    // itself for a title and about two lines beneath it and does not grow past that, so a row carrying an uplift, an
    // exclusion note and an offer to free space painted them outside its own bounds — which nothing revealed until a
    // background made the bounds visible.
    return ColoredBox(
      color: mark?.tile ?? Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          tile,
          if (notes != null)
            Padding(
              // Aligned with the title rather than the edge, so the notes read as belonging to the row above them.
              padding: EdgeInsets.only(left: mark != null || icon != null ? 72 : 16, right: 16, bottom: 12),
              child: notes,
            ),
        ],
      ),
    );
  }
}

/// One option in such a menu. [unavailable] is why it cannot be picked right now, and null when it can.
typedef OfflineChoiceOption = ({OfflineChoice choice, String label, String? unavailable});

/// Words for the library row. "Not selected" names the state; choosing it removes nothing.
const kOfflineLibraryChoices = <OfflineChoiceOption>[
  (choice: OfflineChoice.off, label: 'Not selected', unavailable: null),
  (choice: OfflineChoice.thumbnails, label: 'Thumbnails', unavailable: null),
  (choice: OfflineChoice.previews, label: 'Previews', unavailable: null),
  (choice: OfflineChoice.full, label: 'Full quality', unavailable: null),
  (choice: OfflineChoice.fullWithVideos, label: 'Full quality + videos', unavailable: null),
];

/// One rung, in the words the menus use for it.
String offlineQualityLabel(OfflineQuality quality) => switch (quality) {
  OfflineQuality.none => 'nothing',
  OfflineQuality.thumbnail => 'thumbnails',
  OfflineQuality.preview => 'previews',
  OfflineQuality.full => 'full quality',
  OfflineQuality.fullWithVideos => 'full quality + videos',
};

/// Words for an album row.
List<OfflineChoiceOption> offlineAlbumChoices(OfflinePolicy policy, String albumId) {
  // Excluding is meaningful whenever anything *else* keeps these items — another album naming them just as much as the
  // global settings, which is all this used to ask about. Put to the selection with this album taken out of it, so an
  // album that is the only thing keeping its own items still reads as having nothing to exclude, while one overlapping
  // an included album no longer does.
  final nothingToExclude =
      policy.stateOf(albumId) != OfflineAlbumState.excluded &&
      !policy.withAlbum(albumId, OfflineAlbumState.notIncluded).selectsAnything;

  return [
    (choice: OfflineChoice.off, label: 'Use global settings', unavailable: null),
    (choice: OfflineChoice.thumbnails, label: 'Thumbnails', unavailable: null),
    (choice: OfflineChoice.previews, label: 'Previews', unavailable: null),
    (choice: OfflineChoice.full, label: 'Full quality', unavailable: null),
    (choice: OfflineChoice.fullWithVideos, label: 'Full quality + videos', unavailable: null),
    (
      choice: OfflineChoice.excluded,
      label: 'Exclude from offline',
      unavailable: nothingToExclude ? 'Nothing else keeps these, so there is nothing to exclude' : null,
    ),
  ];
}

OfflineChoice offlineChoiceOfAlbum(OfflinePolicy policy, String albumId) => switch (policy.stateOf(albumId)) {
  OfflineAlbumState.excluded => OfflineChoice.excluded,
  OfflineAlbumState.included => OfflineChoice.ofQuality(policy.albums[albumId]),
  OfflineAlbumState.notIncluded => OfflineChoice.off,
};

OfflinePolicy offlineAlbumPolicy(OfflinePolicy policy, String albumId, OfflineChoice choice) => switch (choice) {
  OfflineChoice.excluded => policy.withAlbum(albumId, OfflineAlbumState.excluded),
  OfflineChoice.off => policy.withAlbum(albumId, OfflineAlbumState.notIncluded),
  _ => policy.withAlbum(albumId, OfflineAlbumState.included, quality: choice.quality),
};
