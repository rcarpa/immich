// The provider lives on the root container and is never disposed.
// ignore_for_file: use-ref-and-state-synchronously

/// immich-sync fork: why the server is unusable, when it is. Auth failures are reported here instead of logging out
/// (FORK.md R2).
library;

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/network_capability_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:logging/logging.dart';

enum SessionIssue {
  /// No usable network. Signing in cannot help.
  offline,

  /// Online, but the server rejected the stored token.
  expired,

  /// Online, but the server did not answer.
  unreachable,

  /// The session could not be set up on this device (storage or platform), so nothing syncs. Not about the token.
  failed,
}

class SessionIssueNotifier extends Notifier<SessionIssue?> {
  @override
  SessionIssue? build() => null;

  /// Bumped by [clear], so a success landing while a report reads the network wins.
  int _clears = 0;

  /// Bumped by [reportReachable], which outdates a pending [reportUnreachable] but not a rejection.
  int _answers = 0;

  /// Records a rejected token, after checking connectivity: in airplane mode a 401 proves nothing.
  Future<void> reportRejected() async {
    final clears = _clears;
    final offline = await _isOffline();
    if (clears != _clears) {
      return;
    }
    if (offline) {
      state = SessionIssue.offline;
      return;
    }
    state = SessionIssue.expired;
  }

  /// Records a server that did not answer. Offline wins, and an [SessionIssue.expired] is kept: the token check at
  /// launch usually fails before the sync does, and only expired shows on the app-bar badge.
  Future<void> reportUnreachable() async {
    final clears = _clears;
    final answers = _answers;
    final offline = await _isOffline();
    if (clears != _clears || answers != _answers) {
      return;
    }
    if (offline) {
      state = SessionIssue.offline;
      return;
    }
    if (state == SessionIssue.expired || state == SessionIssue.failed) {
      return;
    }
    state = SessionIssue.unreachable;
  }

  /// The server answered, though something else failed: only the network issues are cleared.
  void reportReachable() {
    _answers++;
    if (state == SessionIssue.offline || state == SessionIssue.unreachable) {
      state = null;
    }
  }

  /// Records a session that could not be set up locally. Signing in again would not help.
  void reportFailed() {
    state = SessionIssue.failed;
  }

  void clear() {
    // A report may be reading the network right now.
    _clears++;
    if (state != null) {
      state = null;
    }
  }

  Future<bool> _isOffline() async {
    try {
      final capabilities = await ref.read(connectivityApiProvider).getCapabilities();
      return !capabilities.hasWifi && !capabilities.hasCellular && !capabilities.hasVpn;
    } catch (error) {
      Logger('SessionIssue').warning('Could not read connectivity; assuming the network is fine', error);
      // Unknown: assume the network is fine, so an expired session still surfaces.
      return false;
    }
  }
}

final sessionIssueProvider = NotifierProvider<SessionIssueNotifier, SessionIssue?>(SessionIssueNotifier.new);
