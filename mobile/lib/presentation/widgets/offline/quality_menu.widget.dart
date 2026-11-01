/// immich-sync fork: the controls that select what stays offline. Album states follow upstream's `BackupSelection`.
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

  /// Whether the row shows its state as a mark and a tint; only in the album list.
  final bool showState;

  String get _current => labels.firstWhere((option) => option.choice == value, orElse: () => labels.first).label;

  /// Marks as in upstream's `album_info_list_tile.dart`: a check for kept, a minus for excluded, a dot for following
  /// the setting above. Tints are lighter than upstream's, since these rows are taller and exclusion is common.
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
              // Kept in the list but disabled when it cannot be picked, with the reason under it.
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
    // Notes go under the tile rather than in its subtitle, since a `ListTile` does not grow past about two lines.
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
  // Excluding means something whenever anything other than this album keeps these items.
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
