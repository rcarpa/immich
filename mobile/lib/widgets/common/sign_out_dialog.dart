/// immich-sync fork — signing out, with the offline copies spelled out.
library;

import 'package:flutter/material.dart';

enum SignOutChoice {
  /// Sign out, leave the stored files on disk.
  keepOfflineCopies,

  /// Sign out and delete them.
  eraseOfflineCopies,
}

/// Upstream's confirmation says nothing about stored photos, which here is the only question worth asking: signing out
/// empties the local database, but the stored files are untouched and are named after the URLs they came from, so
/// signing back in finds them all valid.
///
/// Deleting them is the one path that abandons the mirror rather than emptying it, so it takes the selection with it —
/// and says so, because deleting the copies while leaving the instruction to fetch them behind would simply download
/// the library again on the next sign-in.
///
/// "Offline copies" throughout, which is what every other screen calls them — the app-bar entry, the settings entry and
/// the screen itself. Calling them downloads here made this the one place using a different word for the same thing,
/// and the word it used is also the name of an unrelated upstream feature that saves to the photo library.
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
