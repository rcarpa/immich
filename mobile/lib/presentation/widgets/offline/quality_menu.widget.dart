/// immich-sync fork — the controls that select what stays available offline. An album borrows upstream's
/// `BackupSelection.selected / none / excluded`.
library;

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';

/// `PopupMenuButton` treats a null result as "dismissed", so every option needs a non-null value of its own.
enum OfflineChoice {
  off,
  previews,
  full,
  fullWithVideos,
  excluded;

  static OfflineChoice ofQuality(OfflineQuality? quality) => switch (quality) {
    OfflineQuality.fullWithVideos => fullWithVideos,
    OfflineQuality.full => full,
    OfflineQuality.preview => previews,
    _ => off,
  };

  OfflineQuality? get quality => switch (this) {
    OfflineChoice.fullWithVideos => OfflineQuality.fullWithVideos,
    OfflineChoice.full => OfflineQuality.full,
    OfflineChoice.previews => OfflineQuality.preview,
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

  String get _current => labels.firstWhere((option) => option.choice == value, orElse: () => labels.first).label;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: icon == null ? null : Icon(icon),
    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: subtitle == null && footer == null
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (subtitle != null) Text(subtitle!),
              ?footer,
            ],
          ),
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
}

/// One option in such a menu. [unavailable] is why it cannot be picked right now, and null when it can.
typedef OfflineChoiceOption = ({OfflineChoice choice, String label, String? unavailable});

/// Words for the library row. "Not selected" names the state; choosing it removes nothing.
const kOfflineLibraryChoices = <OfflineChoiceOption>[
  (choice: OfflineChoice.off, label: 'Not selected', unavailable: null),
  (choice: OfflineChoice.previews, label: 'Previews', unavailable: null),
  (choice: OfflineChoice.full, label: 'Full quality', unavailable: null),
  (choice: OfflineChoice.fullWithVideos, label: 'Full quality + videos', unavailable: null),
];

/// One rung, in the words the menus use for it.
String offlineQualityLabel(OfflineQuality quality) => switch (quality) {
  OfflineQuality.none => 'nothing',
  OfflineQuality.preview => 'previews',
  OfflineQuality.full => 'full quality',
  OfflineQuality.fullWithVideos => 'full quality + videos',
};

/// Words for an album row.
List<OfflineChoiceOption> offlineAlbumChoices(OfflinePolicy policy, String albumId) => [
  (choice: OfflineChoice.off, label: 'Use global settings', unavailable: null),
  (choice: OfflineChoice.previews, label: 'Previews', unavailable: null),
  (choice: OfflineChoice.full, label: 'Full quality', unavailable: null),
  (choice: OfflineChoice.fullWithVideos, label: 'Full quality + videos', unavailable: null),
  (
    choice: OfflineChoice.excluded,
    label: 'Exclude from offline',
    unavailable: policy.library == null && policy.stateOf(albumId) != OfflineAlbumState.excluded
        ? 'The global settings keep nothing, so there is nothing to exclude'
        : null,
  ),
];

OfflineChoice offlineChoiceOfAlbum(OfflinePolicy policy, String albumId) =>
    switch (policy.stateOf(albumId)) {
      OfflineAlbumState.excluded => OfflineChoice.excluded,
      OfflineAlbumState.included => OfflineChoice.ofQuality(policy.albums[albumId]),
      OfflineAlbumState.notIncluded => OfflineChoice.off,
    };

OfflinePolicy offlineAlbumPolicy(OfflinePolicy policy, String albumId, OfflineChoice choice) => switch (choice) {
  OfflineChoice.excluded => policy.withAlbum(albumId, OfflineAlbumState.excluded),
  OfflineChoice.off => policy.withAlbum(albumId, OfflineAlbumState.notIncluded),
  _ => policy.withAlbum(albumId, OfflineAlbumState.included, quality: choice.quality),
};
