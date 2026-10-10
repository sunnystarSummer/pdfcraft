// Finding text, as the engine finds it.
//
// `text_find` does the work and reports view-space rectangles (origin top-left, PDF points,
// /Rotate applied) — the same convention as `text_lines`, which
// `apps/pdfcraft-ffi/tests/text_geometry.rs` pins across the ABI. So the shell only scales them
// to the rendered size; it never re-derives where a word sits on a page.

import 'dart:ui';

import 'engine.dart';

/// One hit: the page it is on, and the rectangles covering it. A match that wraps across lines
/// has more than one rectangle.
class SearchMatch {
  const SearchMatch(this.page, this.text, this.rects);

  factory SearchMatch.fromJson(Map<String, dynamic> json) => SearchMatch(
        json['page'] as int,
        json['text']?.toString() ?? '',
        [
          for (final r in (json['rects'] as List? ?? const []).cast<List>())
            Rect.fromLTRB(
              (r[0] as num).toDouble(),
              (r[1] as num).toDouble(),
              (r[2] as num).toDouble(),
              (r[3] as num).toDouble(),
            ),
        ],
      );

  final int page;
  final String text;
  final List<Rect> rects;
}

/// Everything the reader knows about the current search.
class SearchState {
  const SearchState({this.query = '', this.matches = const [], this.index = -1});

  final String query;
  final List<SearchMatch> matches;

  /// Which match is current, or -1 when there is none.
  final int index;

  bool get isEmpty => matches.isEmpty;
  SearchMatch? get current => index >= 0 && index < matches.length ? matches[index] : null;

  /// How a reader expects to see it: "3 of 12", or "no matches" when a query found nothing.
  String get label {
    if (query.isEmpty) return '';
    if (matches.isEmpty) return 'no matches';
    return '${index + 1} of ${matches.length}';
  }

  /// The rectangles to paint on `page`, with the current match flagged so it can be drawn
  /// differently from the rest.
  List<(Rect, bool)> rectsOn(int page) {
    final out = <(Rect, bool)>[];
    for (var i = 0; i < matches.length; i++) {
      if (matches[i].page != page) continue;
      for (final r in matches[i].rects) {
        out.add((r, i == index));
      }
    }
    return out;
  }

  SearchState step(int by) {
    if (matches.isEmpty) return this;
    final next = (index + by) % matches.length;
    return SearchState(query: query, matches: matches, index: next < 0 ? next + matches.length : next);
  }

  /// Run a query. A limit keeps a pathological query (a single space in a long document) from
  /// returning tens of thousands of rectangles to paint.
  static SearchState run(Engine engine, int doc, String query, {int limit = 500}) {
    if (query.trim().isEmpty) return const SearchState();
    final reply = engine.call('text_find', {'doc': doc, 'query': query, 'limit': limit});
    final matches = [
      for (final m in (reply['matches'] as List? ?? const []).cast<Map<String, dynamic>>())
        SearchMatch.fromJson(m),
    ];
    return SearchState(query: query, matches: matches, index: matches.isEmpty ? -1 : 0);
  }
}
