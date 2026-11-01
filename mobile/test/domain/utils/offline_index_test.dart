/// immich-sync fork: what the badge says and what progress counts. The index is maintained by events, so mistakes in it
/// are silent.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/domain/utils/offline_index.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

const empty = OfflineSegment.empty;
const waiting = OfflineSegment.waiting;
const done = OfflineSegment.done;
const spare = OfflineSegment.spare;

void main() {
  const photo = 'photo-1';
  const video = 'video-1';

  OfflineIndexRow row(
    String id, {
    required OfflineQuality quality,
    required bool isImage,
    bool hasMotion = false,
    int held = 0,
    int token = 1,
    int originalToken = 1,
    int videoToken = 1,
    bool localCopy = false,
    bool errand = false,
    bool onDemand = false,
  }) => OfflineIndexRow(
    assetId: id,
    quality: quality,
    isImage: isImage,
    hasMotion: hasMotion,
    held: held,
    token: token,
    originalToken: originalToken,
    videoToken: videoToken,
    localCopy: localCopy,
    errand: errand,
    onDemand: onDemand,
  );

  late OfflineIndex index;
  setUp(() => index = OfflineIndex());

  group('files a selection implies', () {
    test('a photo needs its original only from full quality up', () {
      index.load([row(photo, quality: OfflineQuality.preview, isImage: true)], heldBytes: 0);
      expect(index.wantedFiles, 2);

      index.setWanted(photo, OfflineQuality.full, isImage: true);
      expect(index.wantedFiles, 3);
    });

    test('a video needs its playable file only at the top rung', () {
      index.load([row(video, quality: OfflineQuality.full, isImage: false)], heldBytes: 0);
      // Full quality is about photos: the video is a still and nothing more.
      expect(index.wantedFiles, 2);

      index.setWanted(video, OfflineQuality.fullWithVideos, isImage: false);
      expect(index.wantedFiles, 3);
    });
  });

  test('a newer version of a file is counted once its predecessor is let go', () {
    index
      ..load([row(photo, quality: OfflineQuality.preview, isImage: true)], heldBytes: 0)
      ..markHeld(photo, OfflineVariant.thumbnail, 1, 10)
      ..markHeld(photo, OfflineVariant.thumbnail, 2, 12);
    expect(index.heldBytes, 22);

    index.dropSupersededBytes(10);
    expect(index.heldBytes, 12);
  });

  test('a reload keeps files not written yet, once they are replayed', () {
    index
      ..load([row(photo, quality: OfflineQuality.preview, isImage: true)], heldBytes: 0)
      ..markHeld(photo, OfflineVariant.thumbnail, 1, 10);

    // `held` does not have the thumbnail yet; the service replays it after loading.
    index
      ..load([row(photo, quality: OfflineQuality.preview, isImage: true)], heldBytes: 0)
      ..markHeld(photo, OfflineVariant.thumbnail, 1, 10, sample: false);
    expect(index.heldBytes, 10);
    expect(index.holds(photo, OfflineVariant.thumbnail, 1), isTrue);

    // Replaying a file `held` already has adds nothing.
    index
      ..load([
        row(photo, quality: OfflineQuality.preview, isImage: true, held: OfflineVariant.thumbnail.bit),
      ], heldBytes: 10)
      ..markHeld(photo, OfflineVariant.thumbnail, 1, 10, sample: false);
    expect(index.heldBytes, 10);
  });

  group('availability', () {
    test('climbs file by file from the thumbnail', () {
      expect(index.availabilityOf(photo), OfflineAvailability.none);

      // The thumbnail alone already draws the item off-grid.
      index.markHeld(photo, OfflineVariant.thumbnail, 1, 10);
      expect(index.availabilityOf(photo), OfflineAvailability.thumbnail);

      index.markHeld(photo, OfflineVariant.preview, 1, 20);
      expect(index.availabilityOf(photo), OfflineAvailability.preview);

      index.markHeld(photo, OfflineVariant.original, 1, 900);
      expect(index.availabilityOf(photo), OfflineAvailability.full);
    });

    test('a video without its playable file is a preview, not a gap', () {
      index.load([row(video, quality: OfflineQuality.full, isImage: false)], heldBytes: 0);
      index.markHeld(video, OfflineVariant.thumbnail, 1, 10);
      index.markHeld(video, OfflineVariant.preview, 1, 20);

      // The still is what that rung asked for, so it is what it can show.
      expect(index.availabilityOf(video), OfflineAvailability.preview);

      index.markHeld(video, OfflineVariant.video, 1, 5000);
      expect(index.availabilityOf(video), OfflineAvailability.full);
    });

    test('a preview without its thumbnail is not available', () {
      index.markHeld(photo, OfflineVariant.preview, 1, 20);
      expect(index.availabilityOf(photo), OfflineAvailability.none);
    });

    test('an unknown asset is not available', () => expect(index.availabilityOf('nobody'), OfflineAvailability.none));
  });

  group('the thumbnail rung', () {
    test('asks for the thumbnail alone, for a photo, a video and a Live Photo', () {
      index.load([
        row(photo, quality: OfflineQuality.thumbnail, isImage: true),
        row(video, quality: OfflineQuality.thumbnail, isImage: false),
      ], heldBytes: 0);
      expect(index.wantedFiles, 2);

      index.setWanted(photo, OfflineQuality.thumbnail, isImage: true, hasMotion: true);
      expect(index.wantedFilesOf(photo), 1);
    });

    test('wants the thumbnail section alone, and fills it when the thumbnail lands', () {
      index.load([row(photo, quality: OfflineQuality.thumbnail, isImage: true)], heldBytes: 0);
      expect(index.barOf(photo), (thumbnail: waiting, preview: empty, full: empty));

      index.markHeld(photo, OfflineVariant.thumbnail, 1, 10);
      expect(index.barOf(photo), (thumbnail: done, preview: empty, full: empty));
    });

    test('a preview kept from a higher rung is a spare beside it', () {
      index.load([row(photo, quality: OfflineQuality.thumbnail, isImage: true)], heldBytes: 0);
      index.markHeld(photo, OfflineVariant.thumbnail, 1, 10);
      index.markHeld(photo, OfflineVariant.preview, 1, 20);
      expect(index.barOf(photo), (thumbnail: done, preview: spare, full: empty));
      expect(index.availabilityOf(photo), OfflineAvailability.preview);
    });

    test('an errand still fetches the whole item', () {
      index.load([row(photo, quality: OfflineQuality.thumbnail, isImage: true, errand: true)], heldBytes: 0);
      expect(index.barOf(photo), (thumbnail: waiting, preview: waiting, full: waiting));
    });
  });

  group('what the camera roll holds', () {
    test('is loaded from the row, since the tile cannot always see it', () {
      index.load([row(photo, quality: OfflineQuality.full, isImage: true, localCopy: true)], heldBytes: 0);

      expect(index.localCopyOf(photo), isTrue);
      expect(index.localCopyOf('nobody'), isFalse);
    });

    test('survives a re-derivation, which knows nothing about the camera roll', () {
      index.load([row(photo, quality: OfflineQuality.preview, isImage: true, localCopy: true)], heldBytes: 0);

      // What applying a selection does. It records a decision; this fact describes the device.
      index.setWanted(photo, OfflineQuality.fullWithVideos, isImage: true);
      expect(index.localCopyOf(photo), isTrue);
    });

    test('an outstanding errand overrides it, as it does for the downloader', () {
      index.load([
        row(photo, quality: OfflineQuality.fullWithVideos, isImage: true, localCopy: true, errand: true),
      ], heldBytes: 0);

      // Both true: the phone has the photo, and the user asked for this app's own copy anyway.
      expect(index.localCopyOf(photo), isTrue);
      expect(index.errandOf(photo), isTrue);

      // Cleared when the errand's files are here, which widens nothing and narrows the target back.
      index.noteErrand(photo, errand: false);
      expect(index.errandOf(photo), isFalse);
      expect(index.localCopyOf(photo), isTrue);
    });

    test('moves when a pass finds the local copy gone', () {
      index.load([row(photo, quality: OfflineQuality.full, isImage: true, localCopy: true)], heldBytes: 0);

      index.noteLocalCopy(photo, localCopy: false);
      expect(index.localCopyOf(photo), isFalse);
    });
  });

  group('the tile bar', () {
    test('fills each section as its own file lands, in whatever order', () {
      index.load([row(photo, quality: OfflineQuality.full, isImage: true)], heldBytes: 0);
      expect(index.barOf(photo), (thumbnail: waiting, preview: waiting, full: waiting));

      // A preview that lands before its thumbnail fills its own section, not the first one.
      index.markHeld(photo, OfflineVariant.preview, 1, 20);
      expect(index.barOf(photo), (thumbnail: waiting, preview: done, full: waiting));

      index.markHeld(photo, OfflineVariant.thumbnail, 1, 10);
      index.markHeld(photo, OfflineVariant.original, 1, 900);
      expect(index.barOf(photo), (thumbnail: done, preview: done, full: done));
    });

    test('an errand over the camera roll fetches a full copy that is a spare', () {
      index.load([
        row(photo, quality: OfflineQuality.fullWithVideos, isImage: true, localCopy: true, errand: true, held: 0x3),
      ], heldBytes: 0);
      // The camera roll holds the original, so no setting maintains a copy of it — but the errand is fetching one.
      expect(index.barOf(photo), (thumbnail: done, preview: done, full: waiting));

      index.markHeld(photo, OfflineVariant.original, 1, 900);
      expect(index.barOf(photo), (thumbnail: done, preview: done, full: spare));
    });

    test('the camera roll leaves the full copy empty when nothing asked for this app\'s own', () {
      index.load([row(photo, quality: OfflineQuality.full, isImage: true, localCopy: true, held: 0x3)], heldBytes: 0);
      expect(index.barOf(photo), (thumbnail: done, preview: done, full: empty));
    });

    test('a previews library that hand-saves an original keeps it a spare', () {
      // Library at previews, *Save offline* tapped, the original arrives: the full-size copy is a spare.
      index.load([row(photo, quality: OfflineQuality.preview, isImage: true, errand: true, held: 0x7)], heldBytes: 0);
      expect(index.barOf(photo), (thumbnail: done, preview: done, full: spare));

      // Once the errand is done the original is no longer being fetched, and it is still a spare.
      index.noteErrand(photo, errand: false);
      expect(index.barOf(photo), (thumbnail: done, preview: done, full: spare));
    });

    test('a hand-fetched row maintains nothing at all', () {
      index.load([
        row(photo, quality: OfflineQuality.fullWithVideos, isImage: true, onDemand: true, held: 0x7),
      ], heldBytes: 0);
      expect(index.barOf(photo), (thumbnail: spare, preview: spare, full: spare));
    });

    test('a Live Photo waits for its motion clip at the rung that asks for videos', () {
      index.load([
        row(photo, quality: OfflineQuality.fullWithVideos, isImage: true, hasMotion: true, held: 0x7),
      ], heldBytes: 0);
      expect(index.barOf(photo).full, waiting);

      index.markHeld(photo, OfflineVariant.video, 1, 3000);
      expect(index.barOf(photo).full, done);
    });

    test('a motion clip left by a higher rung makes the full copy a spare, though the original is library', () {
      index.load([row(photo, quality: OfflineQuality.full, isImage: true, hasMotion: true, held: 0x7)], heldBytes: 0);
      expect(index.barOf(photo).full, done);

      // Kept from when the rung asked for videos: nothing maintains it now, and a cleanup may take it.
      index.markHeld(photo, OfflineVariant.video, 1, 3000);
      expect(index.barOf(photo).full, spare);
    });

    test('a video\'s full copy is its playable file', () {
      index.load([row(video, quality: OfflineQuality.full, isImage: false, held: 0x3)], heldBytes: 0);
      // Full quality without videos keeps a video's still and not the video.
      expect(index.barOf(video), (thumbnail: done, preview: done, full: empty));

      index.markHeld(video, OfflineVariant.video, 1, 3000);
      expect(index.barOf(video).full, spare);
    });

    test('nothing wanted and nothing stored has no bar', () {
      expect(index.barOf('nobody'), kOfflineBarEmpty);
    });
  });

  group('supersession', () {
    test('an edit retires the pair stored under the old cache buster', () {
      index.load([row(photo, quality: OfflineQuality.preview, isImage: true)], heldBytes: 0);
      index.markHeld(photo, OfflineVariant.thumbnail, 1, 10);
      index.markHeld(photo, OfflineVariant.preview, 1, 20);
      expect(index.heldFiles, 2);

      // After an edit the new thumbnail has a new token, and the stored preview shows the old version.
      index.markHeld(photo, OfflineVariant.thumbnail, 2, 11);
      expect(index.holds(photo, OfflineVariant.preview, 1), isFalse);
      expect(index.holds(photo, OfflineVariant.thumbnail, 2), isTrue);
      expect(index.heldFiles, 1);
      expect(index.availabilityOf(photo), OfflineAvailability.thumbnail);
    });

    test('an original from a previous edit is not vouched for', () {
      index.markHeld(photo, OfflineVariant.original, 7, 900);
      expect(index.holds(photo, OfflineVariant.original, 7), isTrue);
      expect(index.holds(photo, OfflineVariant.original, 8), isFalse);
    });

    test('a video retires the generation stored under the other playback setting', () {
      index.load([row(video, quality: OfflineQuality.fullWithVideos, isImage: false)], heldBytes: 0);
      index.markHeld(video, OfflineVariant.thumbnail, 1, 10);
      index.markHeld(video, OfflineVariant.preview, 1, 20);
      index.markHeld(video, OfflineVariant.video, 1, 5000);
      expect(index.heldFiles, 3);

      // Changing `loadOriginalVideo` renames every video.
      index.markHeld(video, OfflineVariant.video, 2, 9000);
      expect(index.holds(video, OfflineVariant.video, 1), isFalse);
      expect(index.holds(video, OfflineVariant.video, 2), isTrue);
      // Still one playable file, however many versions are on disk.
      expect(index.heldFiles, 3);
    });

    test('the same file recorded twice counts once', () {
      index.load([row(photo, quality: OfflineQuality.full, isImage: true)], heldBytes: 0);
      index.markHeld(photo, OfflineVariant.thumbnail, 1, 10);
      index.markHeld(photo, OfflineVariant.preview, 1, 20);
      expect(index.heldFiles, 2);

      // The queue can claim a file and the downloader then report the task it replaced; that must count once.
      index.markHeld(photo, OfflineVariant.preview, 1, 20);
      expect(index.heldFiles, 2);
    });
  });

  group('deselecting', () {
    test('keeps what is stored, so re-selecting costs nothing', () {
      index.load([row(photo, quality: OfflineQuality.full, isImage: true)], heldBytes: 0);
      index.markHeld(photo, OfflineVariant.thumbnail, 1, 10);
      index.markHeld(photo, OfflineVariant.preview, 1, 20);

      index.setWanted(photo, OfflineQuality.none, isImage: true);
      expect(index.wantedAssets, 0);
      expect(index.wantedFiles, 0);
      // The bytes are still there, and still open without a network.
      expect(index.availabilityOf(photo), OfflineAvailability.preview);
      expect(index.heldBytes, 30);

      index.setWanted(photo, OfflineQuality.full, isImage: true);
      // Files already on disk are progress the moment a selection arrives.
      expect(index.heldFiles, 2);
      expect(index.wantedFiles, 3);
    });

    test('forgets an asset that is neither wanted nor stored', () {
      index.setWanted(photo, OfflineQuality.full, isImage: true);
      index.setWanted(photo, OfflineQuality.none, isImage: true);
      expect(index.availabilityOf(photo), OfflineAvailability.none);
      expect(index.wantedAssets, 0);
    });
  });

  test('removing a file takes its bytes with it', () {
    index.load([row(photo, quality: OfflineQuality.full, isImage: true)], heldBytes: 0);
    index.markHeld(photo, OfflineVariant.thumbnail, 1, 10);
    index.markHeld(photo, OfflineVariant.preview, 1, 20);
    index.markHeld(photo, OfflineVariant.original, 1, 900);
    expect(index.heldBytes, 930);

    index.dropHeld(photo, OfflineVariant.original, 900);
    expect(index.heldBytes, 30);
    expect(index.availabilityOf(photo), OfflineAvailability.preview);
  });

  test('a file browsed and then downloaded under the same name is counted once', () {
    // The image path and a download store the same name: one file's bytes.
    index.markHeld(photo, OfflineVariant.preview, 1, 20);
    index.markHeld(photo, OfflineVariant.preview, 1, 20);
    expect(index.heldBytes, 20);
  });

  test('a file claimed before the image path reported it is counted, once', () {
    // The queue claims a file the image path wrote, then the image path reports it.
    index.markHeld(photo, OfflineVariant.thumbnail, 1, 10);
    index.markHeld(photo, OfflineVariant.thumbnail, 1, 10);
    expect(index.heldBytes, 10);
  });

  group('a Live Photo implies one more file', () {
    test('counted the same when the index is loaded from disk', () {
      final index = OfflineIndex();

      index.load([row('live', quality: OfflineQuality.fullWithVideos, isImage: true, hasMotion: true)], heldBytes: 0);

      expect(index.wantedFiles, 4);
    });

    test('four at the videos rung: thumbnail, preview, original and the motion part', () {
      final index = OfflineIndex();

      index.setWanted('live', OfflineQuality.fullWithVideos, isImage: true, hasMotion: true);

      expect(index.wantedFiles, 4);
    });

    test('three below it, since nothing asks for the motion part yet', () {
      final index = OfflineIndex();

      index.setWanted('live', OfflineQuality.full, isImage: true, hasMotion: true);

      expect(index.wantedFiles, 3);
    });

    test('an ordinary photo still implies three', () {
      final index = OfflineIndex();

      index.setWanted('photo', OfflineQuality.fullWithVideos, isImage: true);

      expect(index.wantedFiles, 3);
    });

    test('dropping the rung takes the fourth file back out of the total', () {
      final index = OfflineIndex();
      index.setWanted('live', OfflineQuality.fullWithVideos, isImage: true, hasMotion: true);

      index.setWanted('live', OfflineQuality.full, isImage: true, hasMotion: true);

      expect(index.wantedFiles, 3);
    });
  });

  group('what is left to download', () {
    const kb = 1024;
    const mb = 1024 * 1024;
    final thumbnailAndPreview = OfflineVariant.thumbnail.bit | OfflineVariant.preview.bit;

    OfflineRemaining remaining({bool originalVideos = false}) => index.remaining(originalVideos: originalVideos);

    OfflineSizes size(int original, {int motion = 0, bool isEdited = false}) =>
        (original: original, motion: motion, isEdited: isEdited);

    OfflineIndexRow photoMissingOriginal(String id, {bool localCopy = false}) =>
        row(id, quality: OfflineQuality.full, isImage: true, held: thumbnailAndPreview, localCopy: localCopy);

    test('originals count at their real size, and only those alone are exact', () {
      index.load([photoMissingOriginal(photo), photoMissingOriginal('photo-2')], heldBytes: 0);
      index.applySizes({photo: size(3 * mb), 'photo-2': size(5 * mb)});

      expect(remaining(), (bytes: 8 * mb, exact: true));
    });

    test('sizes are looked up once, and survive a reload', () {
      index.load([photoMissingOriginal(photo)], heldBytes: 0);
      expect(index.lacksSizes(photo), isTrue);
      expect(index.lacksSizes('unknown'), isFalse);

      index.applySizes({photo: size(3 * mb)});
      expect(index.lacksSizes(photo), isFalse);

      index.load([photoMissingOriginal(photo)], heldBytes: 0);
      expect(index.lacksSizes(photo), isFalse);
      expect(remaining().bytes, 3 * mb);
    });

    test('thumbnails and previews count at the defaults until enough arrive, then at their average', () {
      index.load([row(photo, quality: OfflineQuality.preview, isImage: true)], heldBytes: 0);
      expect(remaining(), (bytes: 16 * kb + 170 * kb, exact: false));

      for (var i = 0; i < 20; i++) {
        index.markHeld('arrived-$i', OfflineVariant.thumbnail, 1, 10 * kb);
        index.markHeld('arrived-$i', OfflineVariant.preview, 1, 100 * kb);
      }
      expect(remaining().bytes, 10 * kb + 100 * kb);
    });

    test('a full-size file the camera roll holds is not counted, unless saved by hand', () {
      index.load([photoMissingOriginal(photo, localCopy: true)], heldBytes: 0);
      index.applySizes({photo: size(3 * mb)});
      expect(remaining().bytes, 0);

      index.noteErrand(photo, errand: true);
      index.setWanted(photo, OfflineQuality.full, isImage: true);
      expect(remaining().bytes, 3 * mb);
    });

    test('an edited original is an estimate: only the unedited size is known', () {
      index.load([photoMissingOriginal(photo)], heldBytes: 0);
      index.applySizes({photo: size(3 * mb, isEdited: true)});

      expect(remaining(), (bytes: 3 * mb, exact: false));
    });

    test('an original of unknown size stands in at the average of the known ones', () {
      index.load([photoMissingOriginal(photo), photoMissingOriginal('photo-2')], heldBytes: 0);
      index.applySizes({photo: size(4 * mb)});

      expect(remaining(), (bytes: 8 * mb, exact: false));
    });

    test('videos kept as originals are exact; playback ones shrink by what arrived ones did', () {
      index.load([
        row(video, quality: OfflineQuality.fullWithVideos, isImage: false, held: thumbnailAndPreview),
      ], heldBytes: 0);
      index.applySizes({video: size(100 * mb)});
      expect(remaining(originalVideos: true), (bytes: 100 * mb, exact: true));
      // Assumed as large as the original until enough are stored to learn from.
      expect(remaining(), (bytes: 100 * mb, exact: false));

      // Twenty videos arrive at a quarter of their originals' size.
      for (var i = 0; i < 20; i++) {
        final id = 'arrived-$i';
        index.setWanted(id, OfflineQuality.fullWithVideos, isImage: false);
        index.applySizes({id: size(100 * mb)});
        index.markHeld(id, OfflineVariant.thumbnail, 1, 10 * kb);
        index.markHeld(id, OfflineVariant.preview, 1, 100 * kb);
        index.markHeld(id, OfflineVariant.video, 1, 25 * mb);
      }
      expect(remaining(), (bytes: 25 * mb, exact: false));
    });

    test("a Live Photo's motion part counts at its own size", () {
      index.load([
        row(photo, quality: OfflineQuality.fullWithVideos, isImage: true, hasMotion: true, held: thumbnailAndPreview),
      ], heldBytes: 0);
      index.applySizes({photo: size(3 * mb, motion: 2 * mb)});

      expect(remaining(originalVideos: true), (bytes: 5 * mb, exact: true));
    });

    test('a file landing comes off what is left', () {
      index.load([photoMissingOriginal(photo)], heldBytes: 0);
      index.applySizes({photo: size(3 * mb)});
      expect(remaining().bytes, 3 * mb);

      index.markHeld(photo, OfflineVariant.original, 1, 3 * mb);
      expect(remaining().bytes, 0);
    });
  });
}
