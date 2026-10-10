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

/// A face with CJK coverage, loaded into the same family so glyphs the Latin face lacks fall
/// through to it. Without one, a screenshot of the shell in Japanese or Chinese is a field of
/// boxes and tells a reviewer nothing.
///
/// Single files only: `FontLoader` cannot read a TrueType *collection*, and most system CJK
/// fonts are `.ttc` (Hiragino, STHeiti, Noto CJK). Pointing it at one fails quietly — the
/// strings are right and every glyph still renders as a box, which looks like a translation bug
/// rather than a font one.
///
/// System fonts only: `AGENTS.md` §1.4 forbids committing font files, and the faces the app
/// ships come from craft-fonts at build time.
const _cjkFonts = [
  '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
  '/usr/share/fonts/truetype/arphic/ukai.ttf',
  '/usr/share/fonts/truetype/unfonts-core/UnDotum.ttf',
  r'C:\Windows\Fonts\arialuni.ttf',
];

/// The family the CJK face is registered under, for `fontFamilyFallback`.
const cjkFallbackFamily = 'PdfCraftCJKFallback';

/// Whether a CJK face was found on this machine. False on a system with none, where a
/// screenshot in Japanese is boxes and there is nothing to be done about it here.
bool cjkLoaded = false;

/// What to pass as `fontFamilyFallback` so CJK glyphs render in tests.
List<String> get cjkFallback => cjkLoaded ? const [cjkFallbackFamily] : const [];

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
  // Under its own family, and declared as a fallback by whoever builds the widget tree: extra
  // faces in one family are for weights and styles, not for codepoints a face does not have, so
  // loading it as another 'Roboto' leaves every CJK glyph a box.
  for (final path in _cjkFonts) {
    if (File(path).existsSync()) {
      await _load(cjkFallbackFamily, path);
      cjkLoaded = true;
      break;
    }
  }
  final icons = _materialIcons();
  if (icons != null) await _load('MaterialIcons', icons);
  await testMain();
}
