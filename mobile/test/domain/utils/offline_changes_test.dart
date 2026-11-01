/// immich-sync fork: when a pass is due and when one may settle.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/utils/offline_changes.dart';

void main() {
  late OfflineChanges changes;

  setUp(() => changes = OfflineChanges());

  void settle({int revision = 1, String videoForm = 'video/playback'}) => changes.finish(
    changes.begin(download: true),
    walkedAll: true,
    complete: true,
    download: true,
    upstreamComplete: true,
    revision: revision,
    videoForm: videoForm,
  );

  bool settled({int revision = 1, String videoForm = 'video/playback'}) =>
      changes.isSettled(revision: revision, videoForm: videoForm);

  test('a fresh launch is due a pass, and a complete one settles it', () {
    expect(settled(), isFalse);
    settle();
    expect(settled(), isTrue);
  });

  test('writes, decisions and the video form each make it due again', () {
    settle();
    changes.noteUpstream();
    expect(settled(), isFalse);

    settle();
    changes.noteLocal();
    expect(settled(), isFalse);

    settle();
    expect(settled(revision: 2), isFalse);
    expect(settled(videoForm: 'original'), isFalse);
  });

  test('a pass a write overtook does not settle', () {
    settle();
    changes.noteUpstream();
    final start = changes.begin(download: true);
    changes.noteUpstreamWrite();
    changes.finish(
      start,
      walkedAll: true,
      complete: true,
      download: true,
      upstreamComplete: true,
      revision: 1,
      videoForm: 'video/playback',
    );
    expect(settled(), isFalse);
    expect(changes.upstreamMovedSince(start), isTrue);
  });

  for (final (what, walkedAll, complete, download, upstreamComplete) in [
    ('stopped at its budget', true, false, true, true),
    ('could not enqueue', true, true, false, true),
    ('ran on a half-synced upstream', true, true, true, false),
  ]) {
    test('a pass that $what does not settle', () {
      changes.finish(
        changes.begin(download: download),
        walkedAll: walkedAll,
        complete: complete,
        download: download,
        upstreamComplete: upstreamComplete,
        revision: 1,
        videoForm: 'video/playback',
      );
      expect(settled(), isFalse);
    });
  }

  test('a full walk clears the camera-roll mark unless the camera roll moved during it', () {
    settle();
    changes.noteLocal();
    final start = changes.begin(download: true);
    changes.noteLocal();
    changes.finish(
      start,
      walkedAll: true,
      complete: true,
      download: true,
      upstreamComplete: true,
      revision: 1,
      videoForm: 'video/playback',
    );
    expect(settled(), isFalse);
  });

  test('files let go call for a pass; a failed pass gives its claim back', () {
    settle();
    changes.noteLetGo();
    expect(changes.wantsPass, isTrue);

    final start = changes.begin(download: true);
    expect(changes.wantsPass, isFalse);
    changes.fail(start);
    expect(changes.wantsPass, isTrue);
  });

  test('a pass that only reads figures leaves files let go to the next one', () {
    settle();
    changes.noteLetGo();
    changes.begin(download: false);
    expect(changes.wantsPass, isTrue);
  });
}
