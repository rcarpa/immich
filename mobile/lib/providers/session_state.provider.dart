/// immich-sync fork — why the server is unreachable, when it is. Nothing here navigates away from the library or clears
/// local data on an auth failure (FORK.md R2), so this holds "the session is not currently usable" without acting on
/// it.
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
}

class SessionIssueNotifier extends Notifier<SessionIssue?> {
  @override
  SessionIssue? build() => null;

  /// Records a rejected token, but only after checking connectivity. A 401 is not proof the token is bad: in airplane
  /// mode the request never reaches the server, and a reverse proxy can answer 401 for its own reasons.
  Future<void> reportRejected() async {
    if (await _isOffline()) {
      state = SessionIssue.offline;
      return;
    }
    state = SessionIssue.expired;
  }

  /// Records a server that did not answer. Offline still wins, because that is a fresh reading of the network rather
  /// than a guess, and it is the one state where signing in cannot help.
  ///
  /// But it will not bury an [SessionIssue.expired]: a token the server rejected is the sharper of the two facts, and it
  /// is reported *first* at cold start and on resume — the route guard validates the token in one request while
  /// `syncRemote()` is still working — so a sync failing for the same reason a second later would otherwise overwrite
  /// the expiry with "unreachable". Only expired reaches the app-bar badge, so that badge would appear at launch and
  /// vanish before anyone saw it, coming back only on the next guarded navigation.
  Future<void> reportUnreachable() async {
    if (await _isOffline()) {
      state = SessionIssue.offline;
      return;
    }
    if (state == SessionIssue.expired) {
      return;
    }
    state = SessionIssue.unreachable;
  }

  void clear() {
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
      // Cannot tell: assume the network is fine, so a genuinely expired session
      // still surfaces rather than hiding behind a guess.
      return false;
    }
  }
}

final sessionIssueProvider = NotifierProvider<SessionIssueNotifier, SessionIssue?>(SessionIssueNotifier.new);
