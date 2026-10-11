// The chrome must stay out of the system's own strips.
//
// `Scaffold.body` applies no insets, so anything placed at the end of its `Column` lands in the
// home-indicator strip — 34pt of a 48pt bar on an iPhone 15 Pro, which puts the page buttons
// under the system's swipe area. Landscape adds a notch down one side.
//
// A simulator cannot be driven from `flutter test`, so the insets are injected here instead.
// That is what makes this a regression test rather than a one-off look at a screenshot.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft_flutter/src/viewer.dart';

/// The shell under a device with the given insets.
Future<void> pumpWithInsets(WidgetTester tester, EdgeInsets insets, {Size size = const Size(393, 852)}) async {
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: MediaQueryData(size: size, viewPadding: insets, padding: insets),
        child: const ViewerPage(autoOpen: false),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // iPhone 15 Pro, portrait: the home indicator takes 34pt. The status bar is 59pt but the app
  // bar consumes it, which is why the measured top inset inside the body is 0.
  const portrait = EdgeInsets.only(bottom: 34);

  // The same phone turned on its side: the notch takes a strip off one edge.
  const landscape = EdgeInsets.only(left: 59, right: 59, bottom: 21);

  testWidgets('the page buttons stay above the home indicator', (tester) async {
    await pumpWithInsets(tester, portrait);

    final screen = tester.getSize(find.byType(MaterialApp));
    final safeBottom = screen.height - portrait.bottom;

    for (final tip in ['Previous page', 'Next page']) {
      final box = tester.getRect(find.byTooltip(tip));
      expect(
        box.bottom,
        lessThanOrEqualTo(safeBottom),
        reason: '"$tip" reaches ${box.bottom} but the safe area ends at $safeBottom, '
            'so part of it is under the home indicator',
      );
    }
  });

  testWidgets('the page counter is not under the home indicator either', (tester) async {
    await pumpWithInsets(tester, portrait);
    final screen = tester.getSize(find.byType(MaterialApp));
    final counter = tester.getRect(find.textContaining('of').first);
    expect(counter.bottom, lessThanOrEqualTo(screen.height - portrait.bottom));
  });

  testWidgets('in landscape the chrome clears the notch on both sides', (tester) async {
    await pumpWithInsets(tester, landscape, size: const Size(852, 393));

    final screen = tester.getSize(find.byType(MaterialApp));
    final prev = tester.getRect(find.byTooltip('Previous page'));
    expect(prev.left, greaterThanOrEqualTo(landscape.left), reason: 'left of the notch');

    final status = tester.getRect(find.byType(Row).last);
    expect(status.right, lessThanOrEqualTo(screen.width - landscape.right), reason: 'right of the notch');
    expect(prev.bottom, lessThanOrEqualTo(screen.height - landscape.bottom));
  });

  testWidgets('with no insets nothing is wasted', (tester) async {
    // A device without a notch must not grow a margin: SafeArea of zero is zero.
    await pumpWithInsets(tester, EdgeInsets.zero);
    final screen = tester.getSize(find.byType(MaterialApp));
    final prev = tester.getRect(find.byTooltip('Previous page'));
    expect(screen.height - prev.bottom, lessThan(12), reason: 'the bar should still sit at the bottom edge');
  });
}
