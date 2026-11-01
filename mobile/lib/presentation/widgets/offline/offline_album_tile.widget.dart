/// immich-sync fork: "available offline" on the album itself.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/offline/offline_reclaim_dialog.dart';
import 'package:immich_mobile/presentation/widgets/offline/quality_menu.widget.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';

/// Progress once the album has a setting of its own, and where the decision comes from otherwise. With [stateShown] the
/// row already shows its state, so only the count is printed (*Included* keeps its subtitle).
String offlineAlbumSubtitle(
  WidgetRef ref,
  String albumId,
  OfflinePolicy policy, {
  int? total,
  bool stateShown = false,
}) {
  final items = total == null ? '' : '$total items';
  final count = items.isEmpty ? '' : '$items · ';
  final quiet = stateShown && items.isNotEmpty;
  switch (policy.stateOf(albumId)) {
    case OfflineAlbumState.excluded:
      return quiet ? items : '${count}excluded from offline';
    case OfflineAlbumState.notIncluded:
      return quiet ? items : '${count}using global settings';
    case OfflineAlbumState.included:
      ref.watch(offlineRevisionProvider);
      final ids = ref.watch(offlineAlbumAssetIdsProvider(albumId)).valueOrNull;
      if (ids == null) {
        return '${count}checking…';
      }
      final (wanted: wanted, available: available) = ref.watch(offlineSyncServiceProvider).progressOf(ids);
      return available >= wanted
          ? '$available of $wanted items available offline'
          : '$available of $wanted items downloaded';
  }
}

/// One line under an album row, saying that something outside this album is deciding part of it.
class _OfflineAlbumNote extends StatelessWidget {
  const _OfflineAlbumNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(text, style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.tertiary)),
  );
}

/// What the album asked for, and what it is actually kept at: a lower choice than the library's is overruled, and stays
/// recorded.
class OfflineAlbumUplift extends ConsumerWidget {
  const OfflineAlbumUplift({super.key, required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uplift = ref.watch(offlineAlbumUpliftProvider(albumId)).valueOrNull;
    if (uplift == null) {
      return const SizedBox.shrink();
    }
    final scope = uplift.items == uplift.total ? 'All' : '${uplift.items}';
    return _OfflineAlbumNote('$scope kept at ${offlineQualityLabel(uplift.quality)} by your other settings');
  }
}

/// What an excluded album takes away from this one, so the row explains holding fewer items than the album has.
class OfflineAlbumExcluded extends ConsumerWidget {
  const OfflineAlbumExcluded({super.key, required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final excluded = ref.watch(offlineAlbumExcludedProvider(albumId));
    if (excluded == 0) {
      return const SizedBox.shrink();
    }
    return _OfflineAlbumNote('$excluded excluded by your other settings');
  }
}

/// The note an album shows once its own change has left copies behind.
class OfflineAlbumSpares extends ConsumerWidget {
  const OfflineAlbumSpares({super.key, required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spare = ref.watch(offlineAlbumSpareProvider(albumId));
    if (spare == null || spare.bytes <= 0) {
      return const SizedBox.shrink();
    }
    return OfflineSpareNote(bytes: spare.bytes, assetIds: spare.assetIds);
  }
}

class OfflineAlbumTile extends ConsumerWidget {
  const OfflineAlbumTile({super.key, required this.album});

  final RemoteAlbum album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(offlinePolicyProvider);
    return OfflineSelectionRow(
      icon: Icons.cloud_download_outlined,
      title: 'Available offline',
      subtitle: offlineAlbumSubtitle(ref, album.id, policy),
      value: offlineChoiceOfAlbum(policy, album.id),
      labels: offlineAlbumChoices(policy, album.id),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OfflineAlbumUplift(albumId: album.id),
          OfflineAlbumExcluded(albumId: album.id),
          OfflineAlbumSpares(albumId: album.id),
        ],
      ),
      // The change, not a rebuilt policy, which may be a frame old.
      onSelected: (choice) => unawaited(
        ref.read(offlineSyncServiceProvider).applyPolicy((current) => offlineAlbumPolicy(current, album.id, choice)),
      ),
    );
  }
}
