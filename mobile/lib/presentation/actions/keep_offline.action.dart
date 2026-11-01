/// immich-sync fork: "Save offline" and "Remove offline" on selected items, beside upstream's Download, which saves to
/// the photo library instead.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/offline/offline_reclaim_dialog.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/utils/error_handler.dart';

/// Server assets only.
final _stateProvider = Provider.family.autoDispose<List<RemoteAsset>?, ActionSource>((ref, source) {
  final assets = ref.watch(assetsActionProvider(source));
  final remote = assets.remote().toList(growable: false);
  return remote.isEmpty ? null : remote;
}, dependencies: [assetsActionProvider]);

class KeepOfflineAction extends AssetActionBuilder {
  const KeepOfflineAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(_stateProvider(source));
    if (assets == null) {
      return null;
    }

    ref.watch(offlineRevisionProvider);
    final service = ref.watch(offlineSyncServiceProvider);
    // Asked of the store only: *Save offline* fetches the whole item even when the camera roll holds it.
    final missing = assets.where((asset) => service.availabilityOf(asset.id) != OfflineAvailability.full).length;

    // Offer removal only once every selected item is here.
    return missing > 0
        ? .new(
            icon: Icons.cloud_download_outlined,
            label: assets.length == 1 ? 'Save offline as spare' : 'Save offline as spares',
            onAction: () => _fetch(ref, assets, missing),
          )
        : .new(icon: Icons.cloud_off_outlined, label: 'Remove offline', onAction: () => _release(context, ref, assets));
  }

  Future<void> _fetch(WidgetRef ref, List<RemoteAsset> assets, int missing) async {
    // Read before the await: the menu closes immediately.
    final offlineSync = ref.read(offlineSyncServiceProvider);
    final toast = ref.read(toastServiceProvider);
    final clearSelection = ref.read(clearSelectionProvider(source));

    try {
      await offlineSync.fetchForOffline(assets.map((asset) => asset.id));
      // Confirms the instruction, and says when paused that nothing will arrive yet.
      toast.success(
        offlineSync.current.isPaused
            ? 'Saving as spares — downloading is off, so these arrive when you turn it back on'
            : (missing == 1 ? 'Downloading 1 copy, saved as a spare' : 'Downloading $missing copies, saved as spares'),
      );
      clearSelection();
    } catch (error, stack) {
      handleError(error, stack: stack, description: 'Could not download these for offline use');
    }
  }

  /// Returns these items to what the selection says, then offers to free what that leaves behind.
  Future<void> _release(BuildContext context, WidgetRef ref, List<RemoteAsset> assets) async {
    final offlineSync = ref.read(offlineSyncServiceProvider);
    final clearSelection = ref.read(clearSelectionProvider(source));
    final ids = assets.map((asset) => asset.id).toList();

    try {
      await offlineSync.releaseOnDemand(ids);
      if (!context.mounted) {
        return;
      }
      await confirmFreeUpSpace(context, ref, assetIds: ids);
      clearSelection();
    } catch (error, stack) {
      handleError(error, stack: stack, description: 'Could not remove these from offline storage');
    }
  }
}
