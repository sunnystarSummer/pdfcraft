// Which pages to hold, and which to ask for.
//
// A reader scrolling a 500-page document must not hold 500 rasters: at 150 dpi a Letter page is
// about 8 MB, so the whole document would be gigabytes. It also must not ask for a page it
// already has, or keep asking for pages that have scrolled away. This is that bookkeeping, kept
// apart from the widget so it can be reasoned about and tested on its own.

import 'dart:ui' as ui;

class PageCache {
  PageCache({this.capacity = 24, this.lookahead = 2}) : assert(capacity > 0);

  /// How many rasters to hold. At 150 dpi a Letter page is ~8 MB, so this is the memory budget
  /// divided by page size — 24 pages is roughly 200 MB at that scale, less at phone zoom levels.
  final int capacity;

  /// How far beyond the visible range to render ahead, so scrolling does not reveal blank pages.
  final int lookahead;

  /// Insertion order is recency: a page read or written moves to the end, and eviction takes
  /// from the front.
  final Map<int, ui.Image> _images = {};

  /// Pages already asked for and not yet delivered, so a scroll that does not change the visible
  /// range does not re-queue the same work every frame.
  final Set<int> _pending = {};

  int get length => _images.length;
  Iterable<int> get pages => _images.keys;
  bool contains(int page) => _images.containsKey(page);

  /// The raster for `page`, marking it recently used.
  ui.Image? operator [](int page) {
    final img = _images.remove(page);
    if (img == null) return null;
    _images[page] = img;
    return img;
  }

  /// Take a delivered raster. Pages outside `keep` are evicted first when over capacity, so the
  /// page under the reader's eyes is never the one thrown away.
  void put(int page, ui.Image image, {Set<int> keep = const {}}) {
    _pending.remove(page);
    _images.remove(page)?.dispose();
    _images[page] = image;
    _evict(keep);
  }

  void _evict(Set<int> keep) {
    if (_images.length <= capacity) return;
    for (final page in _images.keys.toList()) {
      if (_images.length <= capacity) return;
      if (keep.contains(page)) continue;
      _images.remove(page)?.dispose();
    }
  }

  /// The pages worth asking for, nearest the middle of the view first.
  ///
  /// `first`..`last` are the visible pages, 1-based and inclusive. The result covers them plus
  /// [lookahead] either side, clamped to the document, skipping anything already held or already
  /// asked for. Ordering matters: the render pool works through the queue in order, so the page
  /// the reader is looking at should not be behind its neighbours.
  List<int> wanted(int first, int last, int pageCount) {
    if (pageCount <= 0) return const [];
    final lo = (first - lookahead).clamp(1, pageCount);
    final hi = (last + lookahead).clamp(1, pageCount);
    final middle = (first + last) ~/ 2;

    final out = <int>[];
    for (var page = lo; page <= hi; page++) {
      if (_images.containsKey(page) || _pending.contains(page)) continue;
      out.add(page);
    }
    out.sort((a, b) => (a - middle).abs().compareTo((b - middle).abs()));
    _pending.addAll(out);
    return out;
  }

  /// Forget that anything is in flight, after the queue is replaced or the zoom changes.
  void forgetPending() => _pending.clear();

  /// Drop every raster, after an edit or a zoom change makes them all wrong.
  void clear() {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    _pending.clear();
  }
}
