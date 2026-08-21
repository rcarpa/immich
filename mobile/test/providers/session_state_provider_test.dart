/// immich-sync fork — the precedence between the three session issues (FORK.md §3.5).
///
/// Cold start and resume both report twice: the route guard validates the token in one request, and `syncRemote()`
/// finishes a second later. The order is what these tests pin down — a sync that merely failed must not overwrite a
/// token the server actually rejected, or the app bar badge appears and vanishes before anyone sees it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/session_state.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../api.mocks.dart';

void main() {
  late MockConnectivityApi connectivity;
  late ProviderContainer container;

  void givenNetwork(List<NetworkCapability> capabilities) {
    when(() => connectivity.getCapabilities()).thenAnswer((_) async => capabilities);
  }

  setUp(() {
    connectivity = MockConnectivityApi();
    givenNetwork([NetworkCapability.wifi]);
    container = ProviderContainer(overrides: [connectivityApiProvider.overrideWithValue(connectivity)]);
    addTearDown(container.dispose);
  });

  SessionIssueNotifier notifier() => container.read(sessionIssueProvider.notifier);
  SessionIssue? issue() => container.read(sessionIssueProvider);

  test('starts with nothing to report', () {
    expect(issue(), isNull);
  });

  test('a rejected token on a working network is expired', () async {
    await notifier().reportRejected();

    expect(issue(), SessionIssue.expired);
  });

  test('a rejected token with no network is offline, not expired', () async {
    givenNetwork([]);

    await notifier().reportRejected();

    // Telling someone to sign in when signing in is impossible is the bug this ordering exists to prevent.
    expect(issue(), SessionIssue.offline);
  });

  test('a failed sync on a working network is unreachable', () async {
    await notifier().reportUnreachable();

    expect(issue(), SessionIssue.unreachable);
  });

  test('a failed sync does not bury an expired token', () async {
    await notifier().reportRejected();

    await notifier().reportUnreachable();

    expect(issue(), SessionIssue.expired);
  });

  test('a rejected token replaces an earlier unreachable', () async {
    await notifier().reportUnreachable();

    await notifier().reportRejected();

    expect(issue(), SessionIssue.expired);
  });

  test('losing the network replaces an expired token, since signing in cannot help', () async {
    await notifier().reportRejected();
    givenNetwork([]);

    await notifier().reportUnreachable();

    expect(issue(), SessionIssue.offline);
  });

  test('a network that came back replaces offline', () async {
    givenNetwork([]);
    await notifier().reportUnreachable();
    givenNetwork([NetworkCapability.cellular]);

    await notifier().reportUnreachable();

    expect(issue(), SessionIssue.unreachable);
  });

  test('a successful sync clears whatever was reported', () async {
    await notifier().reportRejected();

    notifier().clear();

    expect(issue(), isNull);
  });

  test('unreadable connectivity assumes the network is fine, so an expiry still surfaces', () async {
    when(() => connectivity.getCapabilities()).thenThrow(Exception('platform channel unavailable'));

    await notifier().reportRejected();

    expect(issue(), SessionIssue.expired);
  });
}
