/// immich-sync fork: the download order. An errand must not wait behind every preview, and an album switched to full
/// quality mid-sync must still be fetched.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/utils/offline_queue.dart';
import 'package:immich_mobile/utils/offline_paths.dart';

void main() {
  OfflineMissingFile entry(OfflineVariant variant, {int touchedAt = 100, int createdAt = 100, bool isErrand = false}) =>
      OfflineMissingFile(
        'asset-$createdAt',
        OfflineFile('https://photos.example.com/api/assets/asset-$createdAt/thumbnail?size=preview', variant),
        touchedAt: touchedAt,
        createdAt: createdAt,
        isErrand: isErrand,
      );

  List<OfflineVariant> variantsOf(List<OfflineMissingFile> files) => [for (final file in files) file.file.variant];

  group('OfflineMissingFile.compare', () {
    test('an errand comes before every standing decision, however recent', () {
      final files = [
        // The bulk work of a library-wide preview fetch, asked for a moment ago...
        entry(OfflineVariant.thumbnail, touchedAt: 900),
        entry(OfflineVariant.preview, touchedAt: 900),
        // ...and the original of a photo the user just tapped Save offline on, whose own decision is older.
        entry(OfflineVariant.original, touchedAt: 800, isErrand: true),
      ]..sort(OfflineMissingFile.compare);

      expect(files.first.isErrand, isTrue);
    });

    test('within an errand, the cheap files still come first', () {
      final files = [
        entry(OfflineVariant.video, isErrand: true),
        entry(OfflineVariant.original, isErrand: true),
        entry(OfflineVariant.preview, isErrand: true),
        entry(OfflineVariant.thumbnail, isErrand: true),
      ]..sort(OfflineMissingFile.compare);

      expect(variantsOf(files), [
        OfflineVariant.thumbnail,
        OfflineVariant.preview,
        OfflineVariant.original,
        OfflineVariant.video,
      ]);
    });

    test('an album switched to full quality mid-sync outranks the backlog, videos included', () {
      final files = [
        // A hundred thousand missing previews, decided when the library was set to previews.
        entry(OfflineVariant.thumbnail, touchedAt: 100, createdAt: 999),
        entry(OfflineVariant.preview, touchedAt: 100, createdAt: 999),
        // The album ticked ten seconds ago.
        entry(OfflineVariant.video, touchedAt: 200, createdAt: 1),
        entry(OfflineVariant.original, touchedAt: 200, createdAt: 1),
      ]..sort(OfflineMissingFile.compare);

      // The decision, not the ladder, decides between decisions: putting the ladder first stops this album being
      // fetched at all while any preview anywhere is missing.
      expect([for (final file in files) file.touchedAt], [200, 200, 100, 100]);
      expect(variantsOf(files.take(2).toList()), [OfflineVariant.original, OfflineVariant.video]);
    });

    test('within one decision, cheapest and most useful first', () {
      final files = [
        entry(OfflineVariant.video),
        entry(OfflineVariant.original),
        entry(OfflineVariant.preview),
        entry(OfflineVariant.thumbnail),
      ]..sort(OfflineMissingFile.compare);

      expect(variantsOf(files), [
        OfflineVariant.thumbnail,
        OfflineVariant.preview,
        OfflineVariant.original,
        OfflineVariant.video,
      ]);
    });

    test('every thumbnail before any preview, across assets of one decision', () {
      final files = [entry(OfflineVariant.preview, createdAt: 300), entry(OfflineVariant.thumbnail, createdAt: 100)]
        ..sort(OfflineMissingFile.compare);

      expect(variantsOf(files), [OfflineVariant.thumbnail, OfflineVariant.preview]);
    });

    test('ties break on the photo date, newest first', () {
      final files = [
        entry(OfflineVariant.thumbnail, createdAt: 100),
        entry(OfflineVariant.thumbnail, createdAt: 300),
        entry(OfflineVariant.thumbnail, createdAt: 200),
      ]..sort(OfflineMissingFile.compare);

      expect([for (final file in files) file.createdAt], [300, 200, 100]);
    });
  });
}
