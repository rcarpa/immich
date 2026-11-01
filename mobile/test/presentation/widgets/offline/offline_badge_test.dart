/// immich-sync fork — the bar under a tile's glyph: three fixed sections that only change colour.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/presentation/widgets/offline/offline_badge.widget.dart';

void main() {
  const states = OfflineSegment.values;

  Future<void> pump(WidgetTester tester, OfflineBar bar) => tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        // The width the tile gives it: the 16-pixel glyph, inset a pixel each side.
        child: SizedBox(width: 14, child: offlineMeterForTesting(bar)),
      ),
    ),
  );

  /// Where each section sits and how wide it is: the three direct children of the bar's row that are not separators.
  List<Rect> sections(WidgetTester tester) {
    final row = tester.widget<Row>(find.byType(Row));
    return [
      for (final child in row.children)
        if (child is SizedBox && child.width != 1.0) tester.getRect(find.byWidget(child)),
    ];
  }

  /// Widgets of a type inside the bar, and not in the app around it.
  Finder inBar(Type type) => find.descendant(of: find.byType(Row), matching: find.byType(type));

  /// The hairline colours drawn, left to right.
  List<Color> lines(WidgetTester tester) => [
    for (final box in tester.widgetList<ColoredBox>(inBar(ColoredBox))) box.color,
  ];

  testWidgets('every section keeps its place and width whatever any section says', (tester) async {
    await pump(tester, kOfflineBarEmpty);
    final reference = sections(tester);
    expect(reference.map((rect) => rect.width), [2.0, 4.0, 6.0]);
    expect(reference.map((rect) => rect.left), [0.0, 3.0, 8.0]);

    for (final thumbnail in states) {
      for (final preview in states) {
        for (final full in states) {
          await pump(tester, (thumbnail: thumbnail, preview: preview, full: full));
          expect(tester.takeException(), isNull);
          expect(sections(tester), reference, reason: '$thumbnail / $preview / $full');
        }
      }
    }
  });

  testWidgets('only the colour changes: nothing, a bare plate, white, amber', (tester) async {
    await pump(tester, (thumbnail: OfflineSegment.done, preview: OfflineSegment.spare, full: OfflineSegment.waiting));
    expect(lines(tester), [Colors.white, const Color(0xFFFFB020)]);
    // Three sections drawn, two of them with a line: the waiting one is the plate alone.
    expect(inBar(DecoratedBox), findsNWidgets(2 + 1));

    await pump(tester, (thumbnail: OfflineSegment.done, preview: OfflineSegment.empty, full: OfflineSegment.empty));
    expect(lines(tester), [Colors.white]);
    // An empty section draws nothing at all.
    expect(inBar(DecoratedBox), findsOneWidget);
  });
}
