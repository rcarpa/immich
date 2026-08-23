/// immich-sync fork — "available offline" on the album itself. The gesture the feature was asked for: mark *this
/// album*, from the album, rather than three screens away in Settings.
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

/// Progress once the album has a setting of its own, and where the decision comes from otherwise.
///
/// [stateShown] is for a row that already wears its state as a mark and a tint. Those two states have nothing to report
/// beyond the state itself, and the menu beside them names it a third time — so on such a row the words are dropped and
/// the count gets the line to itself, which is what keeps it to one line. *Included* keeps its subtitle either way: how
/// much of the album is actually here is not something a mark can say.
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

/// What the album asked for, and what it is actually kept at.
///
/// A lower choice than the library's is recorded and then overruled, since quality resolves to the most generous
/// setting naming an item. Saying so is what stops the choice looking ignored — and it stays recorded, so lowering the
/// library later hands the album back to its own setting.
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

/// What an *excluded* album takes away from this one.
///
/// The counterpart of [OfflineAlbumUplift] and the same problem seen from the other side: an item's fate is resolved
/// across every album naming it, so a choice made on this row can be overruled from elsewhere. An exclusion is the
/// sharper case — it removes the items rather than raising them — and without a line for it the row simply reports
/// fewer items than the album holds, with nothing anywhere accounting for the difference.
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
      // The change, not a rebuilt policy: `policy` is a frame old, and a tap on
      // another row in between would be overwritten by what it produced.
      onSelected: (choice) => unawaited(
        ref.read(offlineSyncServiceProvider).applyPolicy((current) => offlineAlbumPolicy(current, album.id, choice)),
      ),
    );
  }
}
