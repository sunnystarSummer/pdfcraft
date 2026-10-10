// The agent's way of looking at this shell.
//
// `CLAUDE.md` requires UI work to be looked at. For the egui shell that is
// `pdfcraft-cli ui --control FILE screenshot` against a running app, or
// `cargo run -p pdfcraft-ui-egui --example shot` headless. This is the Flutter equivalent, and
// it is headless too: no window, no display, about a second.
//
// Driven by a JSON script, so one command does the whole thing (see tool/shot.sh):
//
//   PDFCRAFT_SHOT=steps.json flutter test test/shot_test.dart
//
// The script is a list of steps, mirroring `pdfcraft-cli run --script`:
//
//   [{"open": "doc.pdf"}, {"command": "view.zoom_in"}, {"click": "Next page"},
//    {"type": "hello"}, {"inspect": null}, {"shot": "out.png"}]
//
// Without PDFCRAFT_SHOT the test skips, so an ordinary `flutter test` is unaffected.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft_flutter/src/viewer.dart';

void main() {
  final script = Platform.environment['PDFCRAFT_SHOT'];

  testWidgets('scripted shot', (tester) async {
    final steps = (jsonDecode(File(script!).readAsStringSync()) as List).cast<Map<String, dynamic>>();
    final size = _size(Platform.environment['PDFCRAFT_SHOT_SIZE']);
    await tester.binding.setSurfaceSize(size);

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const ViewerPage(autoOpen: false),
    ));
    await tester.pumpAndSettle();
    final state = tester.state<ViewerPageState>(find.byType(ViewerPage));

    for (final step in steps) {
      final entry = step.entries.first;
      final verb = entry.key;
      final arg = entry.value;
      stderr.writeln('step: $verb ${arg ?? ''}');

      switch (verb) {
        case 'open':
          final error = state.openPath(arg as String);
          if (error != null) fail("open $arg: $error");
          await _settleRasters(tester, until: () => state.pageImage != null);
        case 'command':
          final result = await state.runCommand(arg as String);
          if (!result.ok) fail('command $arg: $result');
        case 'menu':
          // Open the registry-driven drawer, then expand one menu by its title so its commands
          // become clickable by label.
          state.scaffoldKey.currentState?.openDrawer();
          await tester.pumpAndSettle();
          if (arg != null) {
            final title = find.text(arg as String);
            expect(title, findsWidgets, reason: 'no menu titled "$arg"');
            await tester.tap(title.first);
            await tester.pumpAndSettle();
          }
        case 'click':
          final target = find.text(arg as String);
          expect(target, findsWidgets, reason: 'no control labelled "$arg"');
          await tester.tap(target.first);
        case 'type':
          await tester.enterText(find.byType(TextField).first, arg as String);
        case 'tap':
          final xy = (arg as List).cast<num>();
          await tester.tapAt(Offset(xy[0].toDouble(), xy[1].toDouble()));
        case 'inspect':
          for (final w in tester.widgetList<Text>(find.byType(Text))) {
            if ((w.data ?? '').trim().isNotEmpty) stderr.writeln('  label: ${w.data}');
          }
        case 'shot':
          // Let anything still rendering land, so a shot is never of a half-drawn viewport.
          await _settleRasters(tester);
          await expectLater(find.byType(MaterialApp), matchesGoldenFile(arg as String));
          stderr.writeln('  wrote $arg');
        default:
          fail('unknown step "$verb"');
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
    }
    stderr.writeln('SHOT OK');
  }, skip: script == null);
}

/// Pump real time so the render pool's results reach the widget tree. The pool runs on its own
/// threads and `poll` decodes asynchronously, neither of which the fake-async test clock drives,
/// so this has to go through `runAsync`.
Future<void> _settleRasters(WidgetTester tester, {bool Function()? until}) async {
  for (var i = 0; i < 60; i++) {
    if (until != null && until()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Size _size(String? spec) {
  final parts = (spec ?? '900x650').split('x');
  return Size(double.parse(parts[0]), double.parse(parts[1]));
}
