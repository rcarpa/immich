/// immich-sync fork — signing out, with the offline copies spelled out.
library;

import 'package:flutter/material.dart';

enum SignOutChoice {
  /// Sign out, leave the stored files on disk.
  keepOfflineCopies,

  /// Sign out and delete them.
  eraseOfflineCopies,
}

/// Sign-out confirmation that also asks about offline copies. Signing out keeps them, and they are valid again after
/// signing back in. Deleting them also clears the selection, or the next sign-in would download it all again.
Future<SignOutChoice?> showSignOutDialog(BuildContext context) => showDialog<SignOutChoice>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Sign out?'),
    content: const Text(
      'Your library will not be visible until you sign in again.\n\n'
      'Offline copies stay on this device, so signing back in restores '
      'everything without downloading it again.\n\n'
      'Deleting them also clears what you chose to keep offline, so nothing '
      'is downloaded again until you choose it.',
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(SignOutChoice.eraseOfflineCopies),
        child: Text(
          'Sign out and delete offline copies',
          style: TextStyle(color: Theme.of(dialogContext).colorScheme.error),
        ),
      ),
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(SignOutChoice.keepOfflineCopies),
        child: const Text('Sign out'),
      ),
    ],
  ),
);
