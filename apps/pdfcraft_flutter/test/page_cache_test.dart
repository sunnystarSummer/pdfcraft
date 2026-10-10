// The reader's memory budget and its request planning, tested without an engine.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft_flutter/src/page_cache.dart';

/// A 1x1 raster standing in for a page. Decoding is real async work, so it has to go through
/// `runAsync`; called from a plain test it never completes.
Future<ui.Image> pixel(WidgetTester tester) async {
  final image = await tester.runAsync(() {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(Uint8List.fromList([0, 0, 0, 255]), 1, 1, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  });
  return image!;
}

void main() {
  test('asks for the visible range plus a lookahead, nearest the middle first', () {
    final cache = PageCache(lookahead: 2);
    // Looking at pages 10-12 of a 100-page document: 8..14, ordered outward from the middle so
    // the page being read is not queued behind its neighbours.
    expect(cache.wanted(10, 12, 100), [11, 10, 12, 9, 13, 8, 14]);
  });

  test('does not ask twice for the same page', () {
    final cache = PageCache(lookahead: 1);
    expect(cache.wanted(5, 5, 100), isNotEmpty);
    expect(cache.wanted(5, 5, 100), isEmpty, reason: 'still in flight');
    cache.forgetPending();
    expect(cache.wanted(5, 5, 100), isNotEmpty, reason: 'the queue was replaced');
  });

  test('clamps to the document and copes with a single page', () {
    final cache = PageCache(lookahead: 3);
    expect(cache.wanted(1, 1, 1), [1]);
    cache.forgetPending();
    final two = cache.wanted(1, 2, 2);
    expect(two, containsAll(<int>[1, 2]));
    expect(two.every((p) => p >= 1 && p <= 2), isTrue, reason: 'never off the end of the document');
    expect(cache.wanted(0, 0, 0), isEmpty, reason: 'no document, nothing to ask for');
  });

  testWidgets('holds at most its capacity, and never evicts what is on screen', (tester) async {
    final cache = PageCache(capacity: 3);
    for (var page = 1; page <= 6; page++) {
      cache.put(page, await pixel(tester), keep: const {5, 6});
    }
    expect(cache.length, lessThanOrEqualTo(3));
    expect(cache.contains(5), isTrue, reason: 'on screen');
    expect(cache.contains(6), isTrue, reason: 'on screen');
    expect(cache.contains(1), isFalse, reason: 'scrolled away long ago');
    cache.clear();
  });

  testWidgets('a page it already holds is not asked for again', (tester) async {
    final cache = PageCache(lookahead: 0);
    cache.put(7, await pixel(tester));
    expect(cache.wanted(7, 7, 100), isEmpty);
    expect(cache[7], isNotNull);
    cache.clear();
  });
}
