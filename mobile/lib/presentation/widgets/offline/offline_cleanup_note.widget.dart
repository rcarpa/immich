/// immich-sync fork: what upstream's "free up space" costs offline. For an item the mirror keeps nothing changes; for
/// one it does not, the photo stops opening without a network.
library;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';

/// What [candidates] would still show offline afterwards. Three levels, because the mirror skips full-size copies while
/// the camera roll holds them, so many of these items only have a preview stored.
({int full, int preview, int thumbnail, int losing}) _outcomeOf(WidgetRef ref, List<LocalAsset> candidates) {
  final service = ref.watch(offlineSyncServiceProvider);
  var full = 0;
  var preview = 0;
  var thumbnail = 0;
  for (final asset in candidates) {
    final remoteId = asset.remoteId;
    switch (remoteId == null ? OfflineAvailability.none : service.availabilityOf(remoteId)) {
      case OfflineAvailability.full:
        full++;
      case OfflineAvailability.preview:
        preview++;
      case OfflineAvailability.thumbnail:
        thumbnail++;
      case OfflineAvailability.none:
        break;
    }
  }
  return (full: full, preview: preview, thumbnail: thumbnail, losing: candidates.length - full - preview - thumbnail);
}

class OfflineCleanupNote extends ConsumerWidget {
  const OfflineCleanupNote({super.key, required this.candidates});

  final List<LocalAsset> candidates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (candidates.isEmpty) {
      return const SizedBox.shrink();
    }

    // The index is in memory, so no loading state.
    ref.watch(offlineRevisionProvider);
    final (full: full, preview: preview, thumbnail: thumbnail, losing: losing) = _outcomeOf(ref, candidates);

    final lines = <(IconData, String, bool)>[
      if (full > 0) (Icons.cloud_download_rounded, '$full stay available offline at full quality', false),
      // Not an error: the photo still opens. The error colour is for items that stop opening.
      if (preview > 0) (Icons.cloud_download_outlined, '$preview stay available offline as previews only', false),
      if (thumbnail > 0) (Icons.cloud_download_outlined, '$thumbnail stay available offline as thumbnails only', false),
      if (losing > 0) (Icons.cloud_outlined, '$losing will need the network', true),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (icon, text, warn) in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                spacing: 8,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 16, color: warn ? context.colorScheme.error : context.colorScheme.onSurfaceVariant),
                  Expanded(
                    child: Text(
                      text,
                      style: context.textTheme.bodySmall?.copyWith(
                        color: warn ? context.colorScheme.error : context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
