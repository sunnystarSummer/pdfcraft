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
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft_flutter/src/i18n.dart';

import 'flutter_test_config.dart' show cjkFallback;
import 'package:pdfcraft_flutter/src/viewer.dart';

void main() {
  final script = Platform.environment['PDFCRAFT_SHOT'];

  testWidgets('scripted shot', (tester) async {
    final steps = (jsonDecode(File(script!).readAsStringSync()) as List).cast<Map<String, dynamic>>();
    final size = _size(Platform.environment['PDFCRAFT_SHOT_SIZE']);
    await tester.binding.setSurfaceSize(size);

    // A real app settles its language before the first frame, and `MaterialApp` reads the locale
    // when it is built, so a `lang` step is applied here rather than when it comes round in the
    // loop. Otherwise Flutter's own strings would stay in the language the app started in.
    for (final step in steps) {
      if (step.containsKey('lang')) {
        catalog = Catalog.load(step['lang'] as String);
        break;
      }
    }

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      // Without this, a screenshot of the shell in Japanese or Chinese is a field of boxes.
      theme: ThemeData(fontFamilyFallback: cjkFallback),
      // The same localisation wiring as `lib/main.dart`, so a screenshot shows what a reader
      // sees — including Flutter's own strings, which are Flutter's to translate.
      locale: localeOf(catalog),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: catalog.languages.isEmpty
          ? const [Locale('en')]
          : [for (final l in catalog.languages) localeOf(Catalog(language: l.code, name: l.name, entries: const {}))],
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
        case 'goto':
          state.goToPage(arg as int);
          await _settleRasters(tester, until: () => state.pageImage != null);
        case 'scroll':
          // Drag the reader by `arg` logical pixels, so continuous scrolling is exercised the
          // way a finger would, not by jumping the controller.
          await tester.drag(find.byType(ListView), Offset(0, -(arg as num).toDouble()));
          await tester.pumpAndSettle();
          await _settleRasters(tester);
        case 'click':
          // A control is "labelled" by its text or, for icon buttons, by its tooltip. An agent
          // should not have to know which, so try text and fall back to the tooltip.
          var target = find.text(arg as String);
          if (target.evaluate().isEmpty) target = find.byTooltip(arg);
          expect(target, findsWidgets, reason: 'nothing labelled "$arg" (try --inspect)');
          await tester.tap(target.first);
        case 'type':
          await tester.enterText(find.byType(TextField).first, arg as String);
        case 'submit':
          // The Enter key, as the platform delivers it: what a field's onSubmitted waits for.
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          await _settleRasters(tester);
        case 'tap':
          final xy = (arg as List).cast<num>();
          await tester.tapAt(Offset(xy[0].toDouble(), xy[1].toDouble()));
        case 'save':
          await state.save(arg as String);
        case 'lang':
          // Already applied before the app was built; this reports what it resolved to.
          stderr.writeln('  language: ${catalog.language} (${catalog.name})'
              '${catalog.isFallback ? ' — fallback, no catalogue for "${catalog.requested}"' : ''}');
          state.showStatus(catalog.name);
          await tester.pumpAndSettle();
        case 'inspect':
          stderr.writeln('  reader: ${state.readerStats}');
          for (final w in tester.widgetList<Text>(find.byType(Text))) {
            if ((w.data ?? '').trim().isNotEmpty) stderr.writeln('  label: ${w.data}');
          }
          // Icon buttons carry their label as a tooltip; without these an agent cannot see
          // half the controls on screen.
          for (final w in tester.widgetList<Tooltip>(find.byType(Tooltip))) {
            if ((w.message ?? '').trim().isNotEmpty) stderr.writeln('  button: ${w.message}');
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
