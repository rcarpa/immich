/// immich-sync fork: confirmation before files are deleted, in terms of what each item is left with.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

/// Offers the reclaim, runs it if confirmed, and returns whether it ran, so the sheet behind it can close.
Future<bool> confirmFreeUpSpace(
  BuildContext context,
  WidgetRef ref, {
  Iterable<String>? assetIds,
  OfflineReclaim what = OfflineReclaim.notMaintained,
}) async {
  final service = ref.read(offlineSyncServiceProvider);
  final plan = await service.reclaimPlan(assetIds: assetIds, what: what);
  if (!context.mounted) {
    return false;
  }

  if (plan.isEmpty) {
    // Scoped and empty means a selection covers these items, not that nothing is stored.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          assetIds == null
              ? 'Nothing to free up.'
              : 'Nothing to remove — your offline settings keep these. Change the album or library setting to stop.',
        ),
      ),
    );
    return false;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Free up ${formatBytes(plan.bytes)}?'),
      content: OfflineReclaimSummary(plan: plan, what: what),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('Free up space', style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
        ),
      ],
    ),
  );

  if (!(confirmed ?? false) || !context.mounted) {
    return false;
  }
  await showOfflineProgress(context, 'Freeing up space…', () => service.freeUpSpace(assetIds: assetIds, what: what));
  return true;
}

/// Confirms the deletion the integrity pass refused as too large to trust unprompted.
Future<void> confirmRefusedReclaim(BuildContext context, WidgetRef ref, int files) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete $files unused files?'),
      content: const Text(
        'Your server no longer lists the photos these files belong to. That is expected if photos were deleted on '
        'the server or you signed in to another account. If the server is still syncing, cancel and wait instead.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('Delete', style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
        ),
      ],
    ),
  );
  if (!(confirmed ?? false) || !context.mounted) {
    return;
  }
  final service = ref.read(offlineSyncServiceProvider);
  await showOfflineProgress(context, 'Deleting unused files…', service.confirmReclaim);
}

/// Runs [action] behind a barrier.
Future<void> showOfflineProgress(BuildContext context, String label, Future<void> Function() action) async {
  final navigator = Navigator.of(context);
  // Pushed synchronously by `showDialog`, so the pop below cannot outrun it.
  final shown = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          spacing: 20,
          children: [
            const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    ),
  );

  var open = true;
  unawaited(shown.then((_) => open = false));
  try {
    await action();
  } finally {
    if (open && navigator.mounted) {
      navigator.pop();
    }
  }
}

class OfflineReclaimSummary extends StatelessWidget {
  const OfflineReclaimSummary({super.key, required this.plan, this.what = OfflineReclaim.notMaintained});

  final OfflineReclaimPlan plan;
  final OfflineReclaim what;

  /// What will happen, composed from what the items are left with — each item in one line only.
  List<(IconData, String, bool)> _lines() {
    return [
      if (plan.removedItems > 0) ...[
        (Icons.cloud_off_outlined, '${plan.removedItems} items will be removed from this device.', true),
        (
          Icons.wifi_off_rounded,
          'Until you are back online they will show as blurred placeholders in the grid, and will not open.',
          false,
        ),
      ],
      if (plan.losingPreviews > 0) ...[
        (Icons.photo_size_select_small_rounded, '${plan.losingPreviews} items will keep only their thumbnail.', false),
        (
          Icons.image_outlined,
          'They will still appear in the grid without a network, and open as that small picture.',
          false,
        ),
      ],
      if (plan.losingOriginals > 0) ...[
        (Icons.sd_rounded, '${plan.losingOriginals} photos will lose their full-size copy.', false),
        (
          Icons.image_outlined,
          'They will still open without a network, as previews. The full-size version stays on your server.',
          false,
        ),
      ],
      if (plan.losingVideos > 0) ...[
        (Icons.videocam_off_outlined, '${plan.losingVideos} videos will be removed from this device.', false),
        (
          Icons.image_outlined,
          'Their stills will stay, so they will still appear in the grid, but playing them will need the network.',
          false,
        ),
      ],
      // Named separately: nothing on the settings screen lists hand-saved items.
      if (plan.handItems > 0)
        (Icons.bookmark_remove_outlined, 'Includes ${_handSaved(plan)} you saved offline by hand.', false),
      // At this depth a selection still wants these files, so downloading stops rather than fetching them back.
      if (what.pauses)
        (
          Icons.pause_circle_outline,
          'Downloading will be turned off. Your selections are kept, so turning it back on downloads them again.',
          false,
        ),
    ];
  }

  static String _handSaved(OfflineReclaimPlan plan) => [
    if (plan.handVideos > 0) '${plan.handVideos} videos (${formatBytes(plan.handVideoBytes)})',
    if (plan.handPhotos > 0) '${plan.handPhotos} photos (${formatBytes(plan.handPhotoBytes)})',
  ].join(' and ');

  @override
  Widget build(BuildContext context) {
    final lines = _lines();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (icon, text, severe) in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              spacing: 12,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: severe ? context.colorScheme.error : context.colorScheme.primary),
                Expanded(
                  child: Text(text, style: severe ? TextStyle(color: context.colorScheme.error) : null),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        // The scope of the dialog in one line.
        Text(
          'Only removes offline copies from this device.',
          style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The note a row shows once its own change has left bytes behind.
class OfflineSpareNote extends ConsumerWidget {
  const OfflineSpareNote({super.key, required this.bytes, required this.assetIds});

  final int bytes;
  final Iterable<String> assetIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (bytes <= 0) {
      return const SizedBox.shrink();
    }
    return InkWell(
      onTap: () => confirmFreeUpSpace(context, ref, assetIds: assetIds),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Free up ${formatBytes(bytes)}',
          style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.primary),
        ),
      ),
    );
  }
}
