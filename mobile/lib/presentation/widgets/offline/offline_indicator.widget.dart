/// immich-sync fork — the second cloud button in the app bar. Beside upstream's backup button, not instead of it:
/// upstream's asks whether the camera roll has reached the server, this one how much of the library would survive
/// losing the network, and opens the screen that decides it.
///
/// It is also where an expired session surfaces on the main page, since nothing else in the app reacts to one (R2).
library;

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';
import 'package:immich_mobile/providers/session_state.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// Matches upstream's `_kBadgeWidgetSize`, so the two buttons are one row.
const double _kBadgeWidgetSize = 30.0;

class OfflineIndicator extends ConsumerWidget {
  const OfflineIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(offlineStatusProvider).valueOrNull;
    final issue = ref.watch(sessionIssueProvider);
    final badge = _badge(context, status, issue);

    return IconButton(
      onPressed: () => unawaited(context.pushRoute(const OfflineSyncRoute())),
      icon: Badge(
        label: badge,
        backgroundColor: Colors.transparent,
        alignment: Alignment.bottomRight,
        isLabelVisible: badge != null,
        offset: const Offset(-2, -12),
        child: Icon(Icons.cloud_download_rounded, size: _kBadgeWidgetSize, color: context.primaryColor),
      ),
    );
  }

  Widget? _badge(BuildContext context, OfflineStatus? status, SessionIssue? issue) {
    final iconColor = context.isDarkTheme ? Colors.white : Colors.black;

    // Above everything else, including a status that has not loaded yet: the app goes on working signed out (R2), so
    // without this the only sign that the session has lapsed is a line on a screen nobody has a reason to open. Expired
    // alone, because it is the only one of the three the user can act on — being offline is what this fork is for, and
    // flagging that would cry wolf. Tapping through lands on the screen that says so and offers the login.
    if (issue == SessionIssue.expired) {
      return _BadgeLabel(
        Icon(
          Icons.close_rounded,
          size: 11,
          color: context.colorScheme.error,
          semanticLabel: 'Signed out on the server',
        ),
        backgroundColor: context.colorScheme.errorContainer,
      );
    }

    if (status == null) {
      return null;
    }

    if (status.wantedAssets == 0) {
      return _BadgeLabel(
        Icon(Icons.cloud_off_rounded, size: 9, color: iconColor, semanticLabel: 'Nothing kept offline'),
      );
    }

    if (status.isPaused && status.missing > 0) {
      return _BadgeLabel(Icon(Icons.pause_rounded, size: 10, color: iconColor, semanticLabel: 'Downloading paused'));
    }

    // Above the spinner, because it is why there is no spinner: downloading has stopped at the ceiling and will not
    // start again on its own.
    if (status.isOverLimit && status.missing > 0) {
      return _BadgeLabel(
        Icon(
          Icons.storage_rounded,
          size: 10,
          color: context.colorScheme.error,
          semanticLabel: 'Storage limit reached, downloading stopped',
        ),
        backgroundColor: context.colorScheme.errorContainer,
      );
    }

    if (status.isWorking || status.queued > 0) {
      return _BadgeLabel(
        Container(
          padding: const EdgeInsets.all(3.5),
          child: Theme(
            data: context.themeData.copyWith(
              progressIndicatorTheme: context.themeData.progressIndicatorTheme.copyWith(year2023: true),
            ),
            child: CircularProgressIndicator(
              strokeWidth: 2,
              strokeCap: StrokeCap.round,
              // Determinate while there is something to measure: a spinner
              // hides the number the user is waiting on.
              value: status.fetchable > 0 ? status.fraction : null,
              valueColor: AlwaysStoppedAnimation<Color>(iconColor),
              semanticsLabel: 'Saving items for offline use',
            ),
          ),
        ),
      );
    }

    if (status.failed > 0) {
      return _BadgeLabel(
        Icon(Icons.warning_rounded, size: 12, color: context.colorScheme.error, semanticLabel: 'Some downloads failed'),
        backgroundColor: context.colorScheme.errorContainer,
      );
    }

    if (status.isComplete) {
      return _BadgeLabel(Icon(Icons.check_outlined, size: 9, color: iconColor, semanticLabel: 'Kept offline'));
    }

    return null;
  }
}

/// Upstream's badge chrome, private to its app bar.
class _BadgeLabel extends StatelessWidget {
  const _BadgeLabel(this.indicator, {this.backgroundColor});

  final Widget indicator;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final opacity = IconTheme.of(context).opacity ?? 1;

    return Container(
      width: _kBadgeWidgetSize / 2,
      height: _kBadgeWidgetSize / 2,
      decoration: BoxDecoration(
        color: (backgroundColor ?? context.colorScheme.surfaceContainer).withValues(alpha: opacity),
        border: Border.all(color: context.colorScheme.outline.withValues(alpha: .3 * opacity)),
        borderRadius: BorderRadius.circular(_kBadgeWidgetSize / 2),
      ),
      child: indicator,
    );
  }
}
