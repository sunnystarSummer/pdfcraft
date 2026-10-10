// The agent-visible surface of the Flutter shell: drive it by label, then screenshot it.
// `flutter test --update-goldens test/viewer_test.dart` writes the images.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft_flutter/src/viewer.dart';

void main() {
  testWidgets('the shell renders its chrome and can be driven by label', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 650));
    // autoOpen: false keeps this test independent of the native library, so the chrome is
    // covered even where the engine has not been built.
    await tester.pumpWidget(const MaterialApp(debugShowCheckedModeBanner: false, home: ViewerPage(autoOpen: false)));
    await tester.pumpAndSettle();

    expect(find.text('PdfCraft'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pumpAndSettle();
    expect(find.text('125%'), findsOneWidget, reason: 'zooming in is reflected in the chrome');

    await tester.tap(find.byTooltip('Zoom out'));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);

    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/shell.png'));
  });

  testWidgets('a long status does not overflow the bottom bar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(393, 852)); // iPhone 15 Pro
    await tester.pumpWidget(const MaterialApp(debugShowCheckedModeBanner: false, home: ViewerPage(autoOpen: false)));
    await tester.pumpAndSettle();

    final state = tester.state<ViewerPageState>(find.byType(ViewerPage));
    state.showStatus('"${'a line of selected text that is far too long to fit ' * 4}"');
    await tester.pumpAndSettle();

    // A RenderFlex overflow is reported as an exception by the test binding.
    expect(tester.takeException(), isNull, reason: 'the status row overflowed');
  });

  testWidgets('zoom is clamped rather than running away', (tester) async {
    await tester.pumpWidget(const MaterialApp(debugShowCheckedModeBanner: false, home: ViewerPage(autoOpen: false)));
    await tester.pumpAndSettle();
    final state = tester.state<ViewerPageState>(find.byType(ViewerPage));

    state.setZoom(1000);
    await tester.pumpAndSettle();
    expect(find.text('800%'), findsOneWidget);

    state.setZoom(0.0001);
    await tester.pumpAndSettle();
    expect(find.text('25%'), findsOneWidget);
  });

  testWidgets('page navigation is disabled when there is nothing to navigate', (tester) async {
    await tester.pumpWidget(const MaterialApp(debugShowCheckedModeBanner: false, home: ViewerPage(autoOpen: false)));
    await tester.pumpAndSettle();
    // byTooltip matches the tooltip wrapper, so reach the button through its icon.
    final prev = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_left));
    final next = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right));
    expect(prev.onPressed, isNull);
    expect(next.onPressed, isNull);
  });
}
