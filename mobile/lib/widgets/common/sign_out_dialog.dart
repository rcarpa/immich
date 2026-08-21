/// immich-sync fork — signing out, with the downloads spelled out.
library;

import 'package:flutter/material.dart';

enum SignOutChoice {
  /// Sign out, leave the downloaded files on disk.
  keepDownloads,

  /// Sign out and delete them.
  eraseDownloads,
}

/// Upstream's confirmation says nothing about stored photos, which here is the only question worth asking: signing out
/// empties the local database, but the downloaded files are untouched and are named after the URLs they came from, so
/// signing back in finds them all valid.
Future<SignOutChoice?> showSignOutDialog(BuildContext context) => showDialog<SignOutChoice>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Sign out?'),
    content: const Text(
      'Your library will not be visible until you sign in again.\n\n'
      'Downloaded copies stay on this device, so signing back in restores '
      'everything without downloading it again.',
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(SignOutChoice.eraseDownloads),
        child: Text(
          'Sign out and delete downloads',
          style: TextStyle(color: Theme.of(dialogContext).colorScheme.error),
        ),
      ),
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(SignOutChoice.keepDownloads),
        child: const Text('Sign out'),
      ),
    ],
  ),
);
