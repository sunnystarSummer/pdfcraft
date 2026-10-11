import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'commands.dart';
import 'engine.dart';
import 'i18n.dart';
import 'page_cache.dart';
import 'search.dart';

/// One line of page text with its view-space rectangle (origin top-left, PDF points).
class TextLine {
  const TextLine(this.text, this.rect);

  factory TextLine.fromJson(Map<String, dynamic> json) {
    final r = (json['rect'] as List).cast<num>();
    return TextLine(
      json['text']?.toString() ?? '',
      Rect.fromLTRB(r[0].toDouble(), r[1].toDouble(), r[2].toDouble(), r[3].toDouble()),
    );
  }

  final String text;
  final Rect rect;
}

/// Draws the selection over the page raster. Rectangles arrive in view-space points and are
/// scaled to the rendered size, so the overlay follows zoom without recomputing geometry.
class _SelectionPainter extends CustomPainter {
  const _SelectionPainter({required this.selection, required this.hits, required this.pageSize});

  /// The selected line, in view-space points.
  final Rect? selection;

  /// Search hits on this page, with a flag for the one the reader is standing on.
  final List<(Rect, bool)> hits;

  final Size pageSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (pageSize.width <= 0 || pageSize.height <= 0) return;
    // View-space points -> the rendered size, so the overlay follows zoom without recomputing
    // any geometry: the rectangles are the engine's.
    final sx = size.width / pageSize.width;
    final sy = size.height / pageSize.height;
    Rect scaled(Rect r) => Rect.fromLTRB(r.left * sx, r.top * sy, r.right * sx, r.bottom * sy);

    for (final (rect, isCurrent) in hits) {
      final box = scaled(rect).inflate(1);
      canvas.drawRect(box, Paint()..color = isCurrent ? const Color(0x99FFC107) : const Color(0x55FFE082));
      if (isCurrent) {
        canvas.drawRect(
          box,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0xCCFF8F00),
        );
      }
    }

    final r = selection;
    if (r != null) {
      final box = scaled(r).inflate(1);
      canvas.drawRect(box, Paint()..color = const Color(0x553B82F6));
      canvas.drawRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xAA3B82F6),
      );
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.selection != selection || old.pageSize != pageSize || old.hits.length != hits.length || old.hits != hits;
}

/// Scale bits in a raster's tag, mirroring the conventions in
/// `crates/ui-egui/src/canvas.rs` so both shells speak the same language.
const int thumbTag = 1 << 63;

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, this.engine, this.autoOpen = true});

  /// Injected by tests; the app builds its own.
  final Engine? engine;
  final bool autoOpen;

  @override
  State<ViewerPage> createState() => ViewerPageState();
}

class ViewerPageState extends State<ViewerPage> {
  Engine? _engine;
  int? _doc;
  int _pageCount = 0;
  int _current = 1;
  double _zoom = 1.0;
  String _status = 'starting';
  bool _dirty = false;
  final List<String> _comments = [];
  Timer? _pump;

  /// The rasters in hand, and the bookkeeping for what to ask for next.
  final PageCache _cache = PageCache();

  final ScrollController _scroll = ScrollController();

  /// Every page's box in PDF points. Pages in one document need not be the same size, so the
  /// reader cannot assume a single geometry.
  List<Size> _pageSizes = const [];

  /// The page the reader is looking at, and the visible range driving tile requests.
  int _firstVisible = 1;
  int _lastVisible = 1;

  /// Set once, when the viewport width is first known: a page that opens wider than the screen
  /// is not a reading experience.
  bool _zoomInitialised = false;

  /// The current page's box, for the selection overlay and hit-testing.
  Size get _pageSize =>
      _pageSizes.isEmpty || _current > _pageSizes.length ? const Size(612, 792) : _pageSizes[_current - 1];

  /// Text lines of the current page, in view space (origin top-left, PDF points), exactly as
  /// `text_lines` returns them. `apps/pdfcraft-ffi/tests/text_geometry.rs` pins that these
  /// survive the ABI unchanged, including under /Rotate.
  List<TextLine> _lines = const [];
  int _selected = -1;

  /// The engine's command registry. Menus, labels, shortcuts and enablement all come from here.
  CommandRegistry _registry = CommandRegistry.empty;

  /// The current search. Hits are painted on every page that has them, not just the one in view.
  SearchState _search = const SearchState();
  bool _searching = false;
  final TextEditingController _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _engine = widget.engine;
    if (widget.autoOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    _pump?.cancel();
    _query.dispose();
    _scroll.dispose();
    _cache.clear();
    if (widget.engine == null) _engine?.close();
    super.dispose();
  }

  Engine get engine => _engine ??= Engine.open();

  Future<void> _start() async {
    try {
      // A few pages, so the shell opens on something that exercises the reader rather than a
      // single page that never scrolls.
      final demo = StringBuffer()
        ..writeln('PdfCraft Flutter shell')
        ..writeln()
        ..writeln(
          'These pages were created through the automation tool table and rasterised by '
          "the engine's own render pool, handed over as premultiplied RGBA8.",
        )
        ..writeln()
        ..writeln(
          'Scroll to read. Only the pages in view are rendered, and the cache keeps at '
          'most a couple of dozen of them, so a long document stays within a fixed memory '
          'budget. Pinch or use the toolbar to zoom. Tap a line to select and copy it. Add a '
          'comment, then save.',
        )
        ..writeln();
      for (var page = 2; page <= 4; page++) {
        for (var line = 0; line < 40; line++) {
          demo.writeln('Page $page, line $line: rendered on demand and dropped when it scrolls away.');
        }
      }
      final created = engine.call('doc_create', {'from': 'text', 'text': demo.toString()});
      _doc = created['doc'] as int;
      _pageCount = created['pages'] as int? ?? 1;
      _loadPage();
      _refreshCommands();
      setState(() => _status = 'opened');
      _request();
      _pump = Timer.periodic(const Duration(milliseconds: 16), (_) => _drain());
    } on EngineError catch (e) {
      setState(() => _status = e.message);
    }
  }

  /// Ask for what the reader can see, plus a little either side.
  ///
  /// `queue` replaces the pending queue rather than appending, which is what makes fast
  /// scrolling cheap: work for pages that have gone by is dropped before it starts.
  void _request({bool force = false}) {
    final doc = _doc;
    if (doc == null) return;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    final scale = _zoom * dpr;
    // After a zoom change what we hold is the wrong resolution, so `wanted` would skip it. The
    // rasters stay on screen, scaled, until their replacements arrive.
    final wanted = force
        ? [for (var p = _firstVisible; p <= _lastVisible; p++) p]
        : _cache.wanted(_firstVisible, _lastVisible, _pageCount);
    if (force) _cache.forgetPending();
    if (wanted.isEmpty) return;
    engine.queue(doc, [for (final page in wanted) TileRequest(page: page, scale: scale, tag: scale.round())]);
  }

  Future<void> _drain() async {
    final doc = _doc;
    if (doc == null || !mounted) return;
    final raster = await engine.poll(doc);
    if (raster == null || !mounted) return;
    setState(
      () => _cache.put(raster.page, raster.image, keep: {for (var p = _firstVisible; p <= _lastVisible; p++) p}),
    );
  }

  /// Every page's geometry, and the text of the page in view.
  void _loadPage() {
    final doc = _doc;
    if (doc == null) return;
    try {
      final info = engine.call('doc_info', {'doc': doc});
      final pages = (info['pages'] as List?) ?? const [];
      _pageSizes = [
        for (final p in pages.cast<Map<String, dynamic>>())
          Size((p['width'] as num).toDouble(), (p['height'] as num).toDouble()),
      ];
      final text = engine.call('text_lines', {'doc': doc, 'page': _current});
      _lines = ((text['lines'] as List?) ?? const [])
          .map((l) => TextLine.fromJson(l as Map<String, dynamic>))
          .toList(growable: false);
      _selected = -1;
    } on EngineError catch (e) {
      setState(() => _status = e.message);
    }
  }

  /// Select the line under a tap. `local` is in widget pixels within the page image.
  /// Select the line under a tap. `local` is in widget pixels within that page's box, and
  /// `page` is the page tapped — in a continuous reader that need not be the current one.
  void selectAt(Offset local, Size rendered, [int? page]) {
    if (page != null && page != _current) {
      setState(() => _current = page);
      _loadPage();
    }
    if (_lines.isEmpty || rendered.width <= 0) return;
    final box = _sizeOf(page ?? _current);
    // Widget pixels -> view-space PDF points.
    final pt = Offset(local.dx / rendered.width * box.width, local.dy / rendered.height * box.height);
    final hit = _lines.indexWhere((l) => l.rect.contains(pt));
    setState(() {
      _selected = hit;
      _status = hit < 0 ? 'no line there' : '"${_lines[hit].text}"';
    });
    if (hit >= 0) Clipboard.setData(ClipboardData(text: _lines[hit].text));
  }

  Future<void> addComment() async {
    final doc = _doc;
    if (doc == null) return;
    try {
      engine.call('comment_add', {
        'doc': doc,
        'page': _current,
        'type': 'note',
        'at': [72, 72],
        'contents': 'Reviewed in the Flutter shell',
        'author': 'PdfCraft',
      });
      final list = engine.call('comment_list', {'doc': doc});
      final items = (list['comments'] as List?) ?? const [];
      setState(() {
        _comments
          ..clear()
          ..addAll(items.map((c) => (c as Map)['contents']?.toString() ?? '(no text)'));
        _dirty = true;
        _status = '${_comments.length} comment(s)';
      });
      _request();
    } on EngineError catch (e) {
      setState(() => _status = e.message);
    }
  }

  Future<void> save(String path) async {
    final doc = _doc;
    if (doc == null) return;
    try {
      engine.call('doc_save', {'doc': doc, 'path': path});
      setState(() {
        _dirty = false;
        _status = 'saved';
      });
    } on EngineError catch (e) {
      setState(() => _status = e.message);
    }
  }

  /// Scroll so `page` is at the top of the viewport.
  void goToPage(int page) {
    if (_pageCount == 0) return;
    final target = page.clamp(1, _pageCount);
    if (!_scroll.hasClients) {
      setState(() => _current = target);
      _loadPage();
      _request();
      return;
    }
    var y = _gap;
    for (var p = 1; p < target; p++) {
      y += _slotHeight(p);
    }
    _scroll.jumpTo(y.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  /// Open a PDF from disk. Returns the error when it fails, so a caller (and the shot driver)
  /// learns why instead of staring at an empty viewport.
  String? openPath(String path) {
    try {
      final opened = engine.call('doc_open', {'path': path});
      setState(() {
        _doc = opened['doc'] as int;
        _pageCount = opened['pages'] as int? ?? 1;
        _current = 1;
        _dirty = false;
        _zoomInitialised = false;
        _firstVisible = 1;
        _lastVisible = 1;
        _cache.clear();
        _status = 'opened';
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _loadPage();
      _refreshCommands();
      _request();
      _pump ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _drain());
      return null;
    } on EngineError catch (e) {
      setState(() => _status = e.message);
      return e.message;
    }
  }

  /// Re-read the registry: `enabled` depends on session state, so it changes with every edit.
  void _refreshCommands() {
    try {
      _registry = CommandRegistry.load(engine, doc: _doc);
    } on EngineError catch (e) {
      _status = e.message;
    }
  }

  CommandRegistry get registry => _registry;

  /// Lets the shot driver open the command drawer without a pointer.
  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

  /// The raster of the page on screen, if one has arrived. The shot driver waits on this so a
  /// screenshot is never taken of an empty viewport.
  ui.Image? get pageImage => _cache[_current];

  /// What the reader is holding, for the shot driver and for diagnosing memory growth.
  String get readerStats =>
      'pages=$_pageCount current=$_current visible=$_firstVisible..$_lastVisible '
      'cached=${_cache.length}/${_cache.capacity} zoom=${(_zoom * 100).round()}%';

  /// Run a registry command by id. This is the Flutter shell's answer to the same question
  /// `crates/ui-egui/src/commands.rs` answers for egui: what does this id do *here*.
  Future<CommandResult> runCommand(String id) async {
    final command = _registry.byId(id);
    if (command == null) return CommandResult(CommandOutcome.unknown, id);

    switch (id) {
      // Zoom is not a registry command: the registry models Acrobat's view modes, which set a
      // page display and a zoom at once. These are the ids that exist.
      case 'view.fit_one_page':
        setZoom(_fitScale(whole: true));
        return const CommandResult(CommandOutcome.done);
      case 'view.fit_width_scrolling':
      case 'view.fit_visible':
        setZoom(_fitScale(whole: false));
        return const CommandResult(CommandOutcome.done);
      case 'comment.note':
        await addComment();
        return const CommandResult(CommandOutcome.done);
      case 'comment.highlight':
        return highlightSelection();

      // Commands whose tool needs arguments the registry does not carry. The egui shell asks
      // the user (a dialog, a selection); on mobile these act on the page in view.
      case 'page.rotate':
        return _viaTool('page_rotate', {
          'degrees': 90,
          'pages': [_current],
        });
      case 'page.rotate_ccw':
        return _viaTool('page_rotate', {
          'degrees': -90,
          'pages': [_current],
        });
      case 'page.duplicate':
        return _viaTool('page_duplicate', {
          'pages': [_current],
        });
      case 'page.insert_blank':
        return _viaTool('page_insert_blank', {'at': _current});
    }

    // Commands the engine can perform on its own, with no arguments beyond the document.
    final tool = command.tool;
    if (tool != null) return _viaTool(tool, {'doc': _doc});

    return CommandResult(CommandOutcome.unsupported, '${command.label} ($id)');
  }

  /// The zoom that fits the page in the viewport, or its width.
  double _fitScale({required bool whole}) {
    final box = context.size;
    if (box == null || _pageSize.width <= 0) return 1.0;
    final byWidth = box.width / _pageSize.width;
    if (!whole) return byWidth;
    return byWidth < box.height / _pageSize.height ? byWidth : box.height / _pageSize.height;
  }

  CommandResult _viaTool(String tool, Map<String, dynamic> args) {
    final doc = _doc;
    if (doc == null) return const CommandResult(CommandOutcome.failed, 'no document');
    try {
      // Tools that change a document return its summary; the page count can have changed.
      final summary = engine.call(tool, {...args, 'doc': doc});
      final pages = summary['pages'];
      if (pages is int && pages > 0) {
        _pageCount = pages;
        if (_current > pages) _current = pages;
      }
      _loadPage();
      _refreshCommands();
      // Keep the stale raster on screen until its replacement arrives, the way
      // `crates/ui-egui/src/canvas.rs` does: clearing it makes the page blink empty on every
      // edit, which is both ugly and a lie about what the document contains.
      //
      // `force`, because after an edit what we hold is out of date but `wanted` would see a
      // page already in the cache and ask for nothing — the edit would never appear.
      setState(() => _dirty = true);
      _request(force: true);
      return const CommandResult(CommandOutcome.done);
    } on EngineError catch (e) {
      setState(() => _status = e.message);
      return CommandResult(CommandOutcome.failed, e.message);
    }
  }

  /// The gap between pages, in logical pixels.
  static const double _gap = 8;

  Size _sizeOf(int page) => page - 1 < _pageSizes.length ? _pageSizes[page - 1] : const Size(612, 792);

  /// A page's height on screen, including the gap below it.
  double _slotHeight(int page) => _sizeOf(page).height * _zoom + _gap;

  /// Open at fit-width rather than at 1 point per pixel, which on a phone shows a sliver.
  void _initialiseZoom(double viewportWidth) {
    if (_zoomInitialised || _pageSizes.isEmpty || viewportWidth <= 0) return;
    _zoomInitialised = true;
    final widest = _pageSizes.map((s) => s.width).reduce((a, b) => a > b ? a : b);
    if (widest > 0) {
      // Scheduled, because this runs during layout.
      final fit = (viewportWidth - 2 * _gap) / widest;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setZoom(fit);
      });
    }
  }

  /// Work out which pages the reader can see, and ask for them if that changed.
  void _onScroll(double viewportHeight) {
    if (!_scroll.hasClients || _pageCount == 0) return;
    final top = _scroll.offset;
    final bottom = top + viewportHeight;

    var y = _gap;
    var first = 1;
    var last = 1;
    var seenFirst = false;
    for (var page = 1; page <= _pageCount; page++) {
      final height = _slotHeight(page);
      if (y + height >= top && !seenFirst) {
        first = page;
        seenFirst = true;
      }
      if (y <= bottom) last = page;
      y += height;
      if (y > bottom) break;
    }

    // The page "in view" is the one covering the middle of the viewport, which is what a reader
    // means by the page they are on.
    final middle = top + viewportHeight / 2;
    var current = first;
    y = _gap;
    for (var page = 1; page <= _pageCount; page++) {
      final height = _slotHeight(page);
      if (middle >= y && middle < y + height) {
        current = page;
        break;
      }
      y += height;
    }

    if (first == _firstVisible && last == _lastVisible && current == _current) return;
    final pageChanged = current != _current;
    setState(() {
      _firstVisible = first;
      _lastVisible = last;
      _current = current;
    });
    if (pageChanged) _loadPage();
    _request();
  }

  /// One page: its raster if we have it, its outline if we do not, and the selection on top.
  Widget _pageBox(int page, double viewportWidth) {
    final size = _sizeOf(page);
    final width = size.width * _zoom;
    final height = size.height * _zoom;
    final img = _cache[page];
    return Padding(
      padding: EdgeInsets.only(bottom: _gap),
      child: Center(
        child: GestureDetector(
          onTapDown: (d) => selectAt(d.localPosition, Size(width, height), page),
          child: Container(
            width: width,
            height: height,
            color: Colors.white,
            child: img == null
                // A page still rendering keeps its space, so the scroll position never jumps.
                ? const SizedBox.expand()
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      RawImage(image: img, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                      CustomPaint(
                        painter: _SelectionPainter(
                          selection: page == _current && _selected >= 0 && _selected < _lines.length
                              ? _lines[_selected].rect
                              : null,
                          hits: _search.rectsOn(page),
                          pageSize: size,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  /// Highlight the selected line.
  ///
  /// The engine wants quads in view space, four corners each (upper-left, upper-right,
  /// lower-left, lower-right). The rectangle is the one `text_lines` gave us, so the highlight
  /// lands exactly on the glyphs rather than on the shell's idea of where they are.
  CommandResult highlightSelection() {
    final doc = _doc;
    if (doc == null) return const CommandResult(CommandOutcome.failed, 'no document');
    if (_selected < 0 || _selected >= _lines.length) {
      return const CommandResult(CommandOutcome.failed, 'select a line first');
    }
    final r = _lines[_selected].rect;
    return _viaTool('comment_add', {
      'page': _current,
      'type': 'highlight',
      'color': 'yellow',
      'quads': [
        [r.left, r.top, r.right, r.top, r.left, r.bottom, r.right, r.bottom],
      ],
    });
  }

  SearchState get search => _search;

  /// Run a search and go to the first hit.
  void find(String query) {
    final doc = _doc;
    if (doc == null) return;
    try {
      setState(() => _search = SearchState.run(engine, doc, query));
      if (_search.current != null) _showMatch();
      showStatus(_search.label);
    } on EngineError catch (e) {
      setState(() => _status = e.message);
    }
  }

  /// Step to the next or previous hit, wrapping at the ends.
  void stepMatch(int by) {
    if (_search.isEmpty) return;
    setState(() => _search = _search.step(by));
    _showMatch();
    showStatus(_search.label);
  }

  void clearSearch() {
    _query.clear();
    setState(() {
      _search = const SearchState();
      _searching = false;
      _status = 'ready';
    });
  }

  /// Scroll so the current hit is in view, a third of the way down, where the eye expects it.
  void _showMatch() {
    final match = _search.current;
    if (match == null || !_scroll.hasClients) return;
    var y = _gap;
    for (var p = 1; p < match.page; p++) {
      y += _slotHeight(p);
    }
    final within = match.rects.isEmpty ? 0.0 : match.rects.first.top * _zoom;
    final viewport = _scroll.position.viewportDimension;
    final target = (y + within - viewport / 3).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(target);
  }

  /// Set the status line (used by tests to exercise long text).
  void showStatus(String text) => setState(() => _status = text);

  void setZoom(double z) {
    final was = _zoom;
    final next = z.clamp(0.25, 8.0);
    if (next == was) return;
    // Keep the reader's place: the page under the middle of the viewport stays there.
    final anchor = _scroll.hasClients ? _scroll.offset : 0.0;
    setState(() => _zoom = next);
    if (_scroll.hasClients && was > 0) {
      final scaled = anchor / was * next;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(scaled.clamp(0.0, _scroll.position.maxScrollExtent));
      });
    }
    _request(force: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: scaffoldKey,
      drawer: _CommandDrawer(
        registry: _registry,
        onRun: (id) async {
          Navigator.of(context).pop();
          final result = await runCommand(id);
          if (!result.ok) showStatus(result.toString());
        },
      ),
      appBar: _searching
          ? AppBar(
              leading: IconButton(onPressed: clearSearch, icon: const Icon(Icons.arrow_back), tooltip: tl('Close')),
              title: TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(hintText: tl('Find text'), border: InputBorder.none),
                onSubmitted: find,
              ),
              actions: [
                Center(child: Text(_search.label)),
                IconButton(
                  onPressed: _search.isEmpty ? null : () => stepMatch(-1),
                  icon: const Icon(Icons.keyboard_arrow_up),
                  tooltip: tl('Previous match'),
                ),
                IconButton(
                  onPressed: _search.isEmpty ? null : () => stepMatch(1),
                  icon: const Icon(Icons.keyboard_arrow_down),
                  tooltip: tl('Next match'),
                ),
              ],
            )
          : AppBar(
              title: Text('PdfCraft${_dirty ? ' •' : ''}'),
              actions: [
                IconButton(
                  onPressed: () => setState(() => _searching = true),
                  icon: const Icon(Icons.search),
                  tooltip: tl('Find…'),
                ),
                IconButton(
                  onPressed: () => setZoom(_zoom / 1.25),
                  icon: const Icon(Icons.zoom_out),
                  tooltip: tl('Zoom out'),
                ),
                Center(child: Text('${(_zoom * 100).round()}%')),
                IconButton(
                  onPressed: () => setZoom(_zoom * 1.25),
                  icon: const Icon(Icons.zoom_in),
                  tooltip: tl('Zoom in'),
                ),
                IconButton(
                  onPressed: addComment,
                  icon: const Icon(Icons.add_comment),
                  tooltip: tl('Add a sticky note'),
                ),
              ],
            ),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: const Color(0xFF3A3A3C),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (_pageCount == 0) {
                    return Center(
                      child: Text(_status, style: const TextStyle(color: Colors.white)),
                    );
                  }
                  _initialiseZoom(constraints.maxWidth);
                  // The dark background runs to the edges, but the pages do not: in landscape
                  // the notch eats a strip down one side, and a page under it is unreadable.
                  // Padding rather than a SafeArea so the background still fills the screen.
                  final side = MediaQuery.viewPaddingOf(context);
                  return NotificationListener<ScrollNotification>(
                    onNotification: (_) {
                      _onScroll(constraints.maxHeight);
                      return false;
                    },
                    child: ListView.builder(
                      controller: _scroll,
                      padding: EdgeInsets.fromLTRB(side.left, _gap, side.right, _gap),
                      itemCount: _pageCount,
                      itemBuilder: (context, index) => _pageBox(index + 1, constraints.maxWidth),
                    ),
                  );
                },
              ),
            ),
          ),
          // `Scaffold.body` applies no insets of its own, so without this the bar sits in the
          // home-indicator strip: on an iPhone 15 Pro that is 34pt of a 48pt bar, putting the
          // page buttons under the system's own swipe area. `top: false` because the app bar
          // has already taken the top inset.
          SafeArea(
            top: false,
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  IconButton(
                    onPressed: _current > 1 ? () => goToPage(_current - 1) : null,
                    icon: const Icon(Icons.chevron_left),
                    tooltip: tl('Previous page'),
                  ),
                  Text(fmt(tl('Page {p} of {n}'), {'p': '$_current', 'n': '$_pageCount'})),
                  IconButton(
                    onPressed: _current < _pageCount ? () => goToPage(_current + 1) : null,
                    icon: const Icon(Icons.chevron_right),
                    tooltip: tl('Next page'),
                  ),
                  const SizedBox(width: 8),
                  // The status carries selected text, which is arbitrarily long: it has to flex
                  // and clip, or the row overflows.
                  Expanded(
                    child: Text(_status, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Menus built from the engine's command registry. Nothing here knows what any command means:
/// the titles, the order, the labels, the shortcuts and the greyed-out state are all the
/// engine's, so this shell and the egui one cannot drift apart.
class _CommandDrawer extends StatelessWidget {
  const _CommandDrawer({required this.registry, required this.onRun});

  final CommandRegistry registry;
  final Future<void> Function(String id) onRun;

  @override
  Widget build(BuildContext context) {
    final menus = registry.menus;
    return Drawer(
      child: SafeArea(
        child: menus.isEmpty
            ? Center(child: Text(tl('No commands')))
            : ListView(
                children: [
                  for (final menu in menus)
                    ExpansionTile(
                      key: ValueKey(menu),
                      title: Text(menu),
                      children: [
                        for (final c in registry.inMenu(menu))
                          ListTile(
                            dense: true,
                            enabled: c.enabled,
                            title: Text(c.label),
                            trailing: c.shortcut == null
                                ? null
                                : Text(c.shortcut!, style: Theme.of(context).textTheme.bodySmall),
                            onTap: c.enabled ? () => onRun(c.id) : null,
                          ),
                      ],
                    ),
                ],
              ),
      ),
    );
  }
}
