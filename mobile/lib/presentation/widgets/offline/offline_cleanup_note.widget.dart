/// immich-sync fork — what "free up space" costs in offline availability. That screen deletes camera-roll originals the
/// server already has, which is safe by its own standard: for an item the mirror keeps, deleting the local original
/// changes nothing visible; for one it does not, the photo silently stops opening without a network.
library;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';

/// What [candidates] would still show with no network afterwards, at the three levels there are.
///
/// Three and not two, because a plain "still available" hides the case that matters most here: the mirror skips an
/// item's full-size copy while the camera roll holds it (FORK.md §3.2), which is exactly the population this screen
/// deletes, so the store often holds the preview and nothing more. Calling those "available offline" is true and
/// useless — the deletion is the moment the phone stops having a full-size copy of them at all, and both ways out
/// (a higher rung, or *Save offline*) are decisions taken before pressing the button rather than after.
({int full, int preview, int losing}) _outcomeOf(WidgetRef ref, List<LocalAsset> candidates) {
  final service = ref.watch(offlineSyncServiceProvider);
  var full = 0;
  var preview = 0;
  for (final asset in candidates) {
    final remoteId = asset.remoteId;
    switch (remoteId == null ? OfflineAvailability.none : service.availabilityOf(remoteId)) {
      case OfflineAvailability.full:
        full++;
      case OfflineAvailability.preview:
        preview++;
      case OfflineAvailability.none:
        break;
    }
  }
  return (full: full, preview: preview, losing: candidates.length - full - preview);
}

class OfflineCleanupNote extends ConsumerWidget {
  const OfflineCleanupNote({super.key, required this.candidates});

  final List<LocalAsset> candidates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (candidates.isEmpty) {
      return const SizedBox.shrink();
    }

    // The availability index is in memory, so this costs no I/O and needs no
    // loading state on a screen that has already made the user wait.
    ref.watch(offlineRevisionProvider);
    final (full: full, preview: preview, losing: losing) = _outcomeOf(ref, candidates);

    final lines = <(IconData, String, bool)>[
      if (full > 0) (Icons.cloud_download_rounded, '$full stay available offline at full quality', false),
      // Stated, not warned about: the photo still opens, and the error colour is reserved for the items that stop
      // opening at all. The words carry the difference, which is what the line exists for.
      if (preview > 0) (Icons.cloud_download_outlined, '$preview stay available offline as previews only', false),
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
                  Icon(
                    icon,
                    size: 16,
                    color: warn ? context.colorScheme.error : context.colorScheme.onSurfaceVariant,
                  ),
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
