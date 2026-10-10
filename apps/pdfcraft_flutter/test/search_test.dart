// Search state: the parts that are arithmetic, and the part that is the engine's.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcraft_flutter/src/engine.dart';
import 'package:pdfcraft_flutter/src/search.dart';

import 'dart:io';

SearchMatch m(int page, double top) =>
    SearchMatch(page, 'hit', [Rect.fromLTRB(10, top, 60, top + 12)]);

void main() {
  final lib = _lib();
  final reason = 'needs the engine: cargo build -p pdfcraft-ffi --release';

  test('stepping wraps at both ends', () {
    var s = SearchState(query: 'x', matches: [m(1, 10), m(2, 20), m(3, 30)], index: 0);
    expect(s.step(1).index, 1);
    expect(s.step(-1).index, 2, reason: 'back from the first wraps to the last');
    s = s.step(1).step(1);
    expect(s.index, 2);
    expect(s.step(1).index, 0, reason: 'past the last wraps to the first');
  });

  test('reads the way a reader expects, including the empty cases', () {
    expect(const SearchState().label, '', reason: 'no query, nothing to say');
    expect(const SearchState(query: 'nope').label, 'no matches');
    expect(SearchState(query: 'x', matches: [m(1, 10), m(2, 20)], index: 1).label, '2 of 2');
  });

  test('hits are painted on the page they are on, and the current one is flagged', () {
    final s = SearchState(query: 'x', matches: [m(1, 10), m(2, 20), m(2, 40)], index: 2);
    expect(s.rectsOn(1).length, 1);
    expect(s.rectsOn(1).single.$2, isFalse, reason: 'not the current match');
    final onTwo = s.rectsOn(2);
    expect(onTwo.length, 2);
    expect(onTwo.where((h) => h.$2).length, 1, reason: 'exactly one current match');
    expect(s.rectsOn(9), isEmpty);
  });

  test('stepping an empty search does nothing rather than dividing by zero', () {
    const s = SearchState(query: 'nope');
    expect(s.step(1).index, -1);
    expect(s.current, isNull);
  });

  test('finds real text, with the engine reporting where it sits', () {
    final engine = Engine.open();
    addTearDown(engine.close);
    final doc = engine.call('doc_create', {
      'from': 'text',
      'text': 'Findable needle here.\n\nAnother line.\n\nThe needle appears twice.',
    })['doc'] as int;

    final hits = SearchState.run(engine, doc, 'needle');
    expect(hits.matches.length, 2, reason: 'both occurrences');
    expect(hits.index, 0, reason: 'lands on the first');
    expect(hits.label, '1 of 2');
    for (final match in hits.matches) {
      expect(match.rects, isNotEmpty);
      // View space: origin top-left, inside the page, normalized.
      for (final r in match.rects) {
        expect(r.left, lessThanOrEqualTo(r.right));
        expect(r.top, lessThanOrEqualTo(r.bottom));
        expect(r.left, greaterThanOrEqualTo(-0.01));
      }
    }

    expect(SearchState.run(engine, doc, '   ').matches, isEmpty, reason: 'blank query is not a search');
    expect(SearchState.run(engine, doc, 'haystack').label, 'no matches');
  }, skip: lib == null ? reason : null);
}

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
