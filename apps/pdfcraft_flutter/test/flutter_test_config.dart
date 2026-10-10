// Golden screenshots are how an agent (and a human) looks at UI work here, mirroring
// `cargo run -p pdfcraft-ui-egui --example shot` for the egui shell. The test harness ships no
// real fonts, so without this every glyph renders as a filled box and the screenshots are
// useless for review. Load a text face and the Material icon face before any test runs.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _textFonts = [
  '/System/Library/Fonts/Supplemental/Arial.ttf',
  '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  r'C:\Windows\Fonts\arial.ttf',
];

Future<void> _load(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) return;
  final bytes = file.readAsBytesSync();
  await (FontLoader(family)..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
}

/// The Material icon font lives in the Flutter SDK, next to the `flutter` command.
String? _materialIcons() {
  final exe = Platform.environment['FLUTTER_ROOT'] ?? Platform.resolvedExecutable;
  for (var dir = Directory(exe); dir.path != dir.parent.path; dir = dir.parent) {
    final candidate = File('${dir.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final path in _textFonts) {
    if (File(path).existsSync()) {
      await _load('Roboto', path);
      break;
    }
  }
  final icons = _materialIcons();
  if (icons != null) await _load('MaterialIcons', icons);
  await testMain();
}
