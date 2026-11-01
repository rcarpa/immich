/// immich-sync fork: which files each rung keeps, and what the camera roll and an errand change.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/utils/offline_files.dart';
import 'package:immich_mobile/infrastructure/repositories/offline.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

import '../../medium/repository_context.dart';

OfflineAsset _asset({
  bool isImage = true,
  String thumbHash = 'hash',
  String? motion,
  bool local = false,
  bool edited = false,
  String? checksum = 'sha1',
}) => OfflineAsset(
  id: 'a',
  thumbHash: thumbHash,
  isImage: isImage,
  isEdited: edited,
  createdAt: DateTime(2026),
  motionVideoId: motion,
  hasLocalCopy: local,
  originalChecksum: checksum,
);

List<OfflineVariant> _variants(OfflineAsset asset, OfflineQuality quality, {bool errand = false}) => [
  for (final file in offlineFilesFor(asset, quality, errand: errand, videoForm: 'video/playback')) file.variant,
];

void main() {
  late MediumRepositoryContext ctx;

  setUpAll(() async {
    ctx = MediumRepositoryContext();
    await StoreService.init(storeRepository: StoreRepository(ctx.db), listenUpdates: false);
    await StoreService.I.put(StoreKey.serverEndpoint, 'https://photos.example.com/api');
  });

  tearDownAll(() async {
    await StoreService.I.dispose();
    await ctx.dispose();
  });

  test('each rung adds to the one below', () {
    final photo = _asset();
    expect(_variants(photo, OfflineQuality.none), isEmpty);
    expect(_variants(photo, OfflineQuality.thumbnail), [OfflineVariant.thumbnail]);
    expect(_variants(photo, OfflineQuality.preview), [OfflineVariant.thumbnail, OfflineVariant.preview]);
    expect(_variants(photo, OfflineQuality.full), [
      OfflineVariant.thumbnail,
      OfflineVariant.preview,
      OfflineVariant.original,
    ]);
  });

  test("a Live Photo's motion part comes with videos, a video's playable file likewise", () {
    expect(_variants(_asset(motion: 'm'), OfflineQuality.full), isNot(contains(OfflineVariant.video)));
    expect(_variants(_asset(motion: 'm'), OfflineQuality.fullWithVideos), contains(OfflineVariant.video));
    expect(_variants(_asset(isImage: false), OfflineQuality.full), [OfflineVariant.thumbnail, OfflineVariant.preview]);
    expect(_variants(_asset(isImage: false), OfflineQuality.fullWithVideos), [
      OfflineVariant.thumbnail,
      OfflineVariant.preview,
      OfflineVariant.video,
    ]);
  });

  test('the camera roll holding it skips the full-size file, unless saved by hand', () {
    final local = _asset(local: true, motion: 'm');
    expect(_variants(local, OfflineQuality.fullWithVideos), [OfflineVariant.thumbnail, OfflineVariant.preview]);
    expect(_variants(local, OfflineQuality.thumbnail, errand: true), [
      OfflineVariant.thumbnail,
      OfflineVariant.preview,
      OfflineVariant.original,
      OfflineVariant.video,
    ]);
  });

  test('an edited photo is fetched whatever the camera roll holds, which is the pre-edit file', () {
    expect(_variants(_asset(local: true, edited: true), OfflineQuality.full), contains(OfflineVariant.original));
  });

  test('nothing before the server has a thumbhash', () {
    expect(_variants(_asset(thumbHash: ''), kOfflineErrandQuality), isEmpty);
  });

  test('only a file the server hashed is checked against its checksum', () {
    OfflineFile? of(List<OfflineFile> files, OfflineVariant variant) =>
        files.where((file) => file.variant == variant).firstOrNull;
    final photo = offlineFilesFor(_asset(), OfflineQuality.full, videoForm: 'video/playback');
    expect(of(photo, OfflineVariant.original)?.checksum, 'sha1');
    expect(of(photo, OfflineVariant.preview)?.checksum, isNull);

    final video = _asset(isImage: false);
    expect(
      of(offlineFilesFor(video, kOfflineErrandQuality, videoForm: 'video/playback'), OfflineVariant.video)?.checksum,
      isNull,
    );
    expect(
      of(offlineFilesFor(video, kOfflineErrandQuality, videoForm: 'original'), OfflineVariant.video)?.checksum,
      'sha1',
    );
  });
}
