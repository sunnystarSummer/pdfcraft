// The vertical slice against the real engine: open, render, comment, save, reopen.
//
// Needs the cdylib. Build it with `cargo build -p pdfcraft-ffi --release` and point
// PDFCRAFT_FFI_LIB at it (tool/macos.sh does this for the app bundle):
//
//   PDFCRAFT_FFI_LIB=../../target/release/libpdfcraft_ffi.dylib flutter test test/engine_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft_flutter/src/engine.dart';
import 'package:pdfcraft_flutter/src/viewer.dart';

String? _lib() {
  final env = Platform.environment['PDFCRAFT_FFI_LIB'];
  if (env != null && File(env).existsSync()) return env;
  for (final guess in [
    '../../target/release/libpdfcraft_ffi.dylib',
    '../../target/debug/libpdfcraft_ffi.dylib',
  ]) {
    if (File(guess).existsSync()) return File(guess).absolute.path;
  }
  return null;
}

void main() {
  final lib = _lib();
  final reason = 'needs the engine: cargo build -p pdfcraft-ffi --release';

  test('a document round-trips through the ABI: create, comment, save, reopen', () async {
    final dir = Directory.systemTemp.createTempSync('pdfcraft-flutter-');
    final engine = Engine.open(root: dir.path);
    addTearDown(() {
      engine.close();
      dir.deleteSync(recursive: true);
    });

    final created = engine.call('doc_create', {'from': 'text', 'text': 'Slice under test.'});
    final doc = created['doc'] as int;
    expect(created['pages'], 1);

    engine.call('comment_add', {
      'doc': doc,
      'page': 1,
      'type': 'note',
      'at': [72, 72],
      'contents': 'Reviewed in the Flutter shell',
      'author': 'PdfCraft',
    });

    final listed = engine.call('comment_list', {'doc': doc});
    final comments = (listed['comments'] as List).cast<Map<String, dynamic>>();
    expect(comments, hasLength(1));
    expect(comments.single['contents'], 'Reviewed in the Flutter shell');

    engine.call('doc_save', {'doc': doc, 'path': 'slice.pdf'});
    expect(File('${dir.path}/slice.pdf').existsSync(), isTrue, reason: 'save wrote the file');

    // Reopen the saved file: the comment must have survived the round trip.
    final reopened = engine.call('doc_open', {'path': 'slice.pdf'});
    final again = engine.call('comment_list', {'doc': reopened['doc']});
    expect((again['comments'] as List), hasLength(1), reason: 'the comment survived save/reopen');
  }, skip: lib == null ? reason : null);

  test('a queued page comes back as a decodable image', () async {
    final engine = Engine.open();
    addTearDown(engine.close);

    final created = engine.call('doc_create', {'from': 'text', 'text': 'Raster under test.'});
    final doc = created['doc'] as int;
    engine.queue(doc, [const TileRequest(page: 1, scale: 2.0, tag: 42)]);

    PageRaster? raster;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (raster == null && DateTime.now().isBefore(deadline)) {
      raster = await engine.poll(doc);
      if (raster == null) await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(raster, isNotNull, reason: 'no raster arrived within 30s');
    expect(raster!.page, 1);
    expect(raster.tag, 42, reason: 'the staleness tag comes back');
    expect(raster.image.width, greaterThan(0));
    expect(raster.image.height, greaterThan(0));
    raster.image.dispose();
  }, skip: lib == null ? reason : null);

  test('text lines come back as usable view-space rectangles', () {
    final engine = Engine.open();
    addTearDown(engine.close);

    final created = engine.call('doc_create', {'from': 'text', 'text': 'Selectable line one.\n\nSelectable line two.'});
    final doc = created['doc'] as int;

    final info = engine.call('doc_info', {'doc': doc});
    final page = (info['pages'] as List).first as Map<String, dynamic>;
    final w = (page['width'] as num).toDouble();
    final h = (page['height'] as num).toDouble();

    final text = engine.call('text_lines', {'doc': doc, 'page': 1});
    final lines = ((text['lines'] as List?) ?? const []).map((l) => TextLine.fromJson(l as Map<String, dynamic>)).toList();

    expect(lines, isNotEmpty, reason: 'the fixture has text');
    for (final line in lines) {
      expect(line.text, isNotEmpty);
      // View space: origin top-left, normalized, inside the page box. These are the coordinates
      // the tap hit-test works in, so a convention slip here is a mis-selection on screen.
      expect(line.rect.left, lessThanOrEqualTo(line.rect.right));
      expect(line.rect.top, lessThanOrEqualTo(line.rect.bottom));
      expect(line.rect.left, greaterThanOrEqualTo(-0.01));
      expect(line.rect.top, greaterThanOrEqualTo(-0.01));
      expect(line.rect.right, lessThanOrEqualTo(w + 0.01));
      expect(line.rect.bottom, lessThanOrEqualTo(h + 0.01));
    }

    // A point inside the first line's rect must hit that line and nothing earlier.
    final first = lines.first.rect;
    final probe = first.center;
    final hit = lines.indexWhere((l) => l.rect.contains(probe));
    expect(hit, 0, reason: 'the first line should be hit at its own centre');
  }, skip: lib == null ? reason : null);

  test('a failing tool surfaces as EngineError, not a crash', () {
    final engine = Engine.open();
    addTearDown(engine.close);
    expect(() => engine.call('no_such_tool'), throwsA(isA<EngineError>()));
    expect(() => engine.call('doc_info', {'doc': 999}), throwsA(isA<EngineError>()));
  }, skip: lib == null ? reason : null);
}
