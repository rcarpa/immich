/// immich-sync fork (R2): no automatic path may open the login screen, log out or clear the synced library. Every call
/// site is listed here with why it is allowed, so a rebase that brings a new one fails until someone has looked at it.
/// The same list is in FORK.md, R2.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Navigating to the login screen, logging out, or clearing local data.
final _sensitive = RegExp(r'\b(LoginRoute(\(|\.name)|clearLocalData\(|logout\()');

/// Where each may appear, and how often.
const _allowed = {
  // No access token stored: a session that was never there.
  'lib/routing/auth_guard.dart': 1,
  // Token, server URL or endpoint missing.
  'lib/pages/common/splash_screen.page.dart': 2,
  // The user pressed Sign out.
  'lib/widgets/common/app_bar_dialog/app_bar_dialog.dart': 2,
  // The user tapped the expired-session note; clears nothing.
  'lib/presentation/pages/offline_sync.page.dart': 1,
  // First sign-in password change.
  'lib/widgets/forms/change_password_form.dart': 1,
  // The implementation those call, and the server's logout endpoint.
  'lib/providers/auth.provider.dart': 2,
  'lib/services/auth.service.dart': 5,
  'lib/repositories/auth.repository.dart': 1,
  'lib/repositories/auth_api.repository.dart': 2,
};

void main() {
  test('every path to the login screen, a logout or a wipe is one FORK.md R2 allows', () {
    final found = <String, int>{};
    final lines = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      final path = entity.path.replaceAll(r'\', '/');
      if (entity is! File || !path.endsWith('.dart') || path.endsWith('.g.dart') || path.endsWith('.gr.dart')) {
        continue;
      }
      var number = 0;
      for (final line in entity.readAsLinesSync()) {
        number++;
        final count = _sensitive.allMatches(line).length;
        if (count > 0) {
          found[path] = (found[path] ?? 0) + count;
          lines.add('$path:$number: ${line.trim()}');
        }
      }
    }

    expect(
      found,
      _allowed,
      reason:
          'A call site that can open the login screen, log out or clear local data moved. If an automatic path '
          'reaches it, it breaks R2; otherwise update FORK.md R2 and this list.\n${lines.join('\n')}',
    );
  });
}
