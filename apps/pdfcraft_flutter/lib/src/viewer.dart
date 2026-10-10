import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'engine.dart';

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
  const _SelectionPainter(this.rect, this.pageSize);

  final Rect? rect;
  final Size pageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null || pageSize.width <= 0 || pageSize.height <= 0) return;
    final sx = size.width / pageSize.width;
    final sy = size.height / pageSize.height;
    final scaled = Rect.fromLTRB(r.left * sx, r.top * sy, r.right * sx, r.bottom * sy);
    canvas.drawRect(scaled.inflate(1), Paint()..color = const Color(0x553B82F6));
    canvas.drawRect(
      scaled.inflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xAA3B82F6),
    );
  }

  @override
  bool shouldRepaint(_SelectionPainter old) => old.rect != rect || old.pageSize != pageSize;
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
  final Map<int, ui.Image> _pages = {};
  final List<String> _comments = [];
  Timer? _pump;

  /// The page box in PDF points, as the engine reports it.
  Size _pageSize = const Size(612, 792);

  /// Text lines of the current page, in view space (origin top-left, PDF points), exactly as
  /// `text_lines` returns them. `apps/pdfcraft-ffi/tests/text_geometry.rs` pins that these
  /// survive the ABI unchanged, including under /Rotate.
  List<TextLine> _lines = const [];
  int _selected = -1;

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
    for (final img in _pages.values) {
      img.dispose();
    }
    if (widget.engine == null) _engine?.close();
    super.dispose();
  }

  Engine get engine => _engine ??= Engine.open();

  Future<void> _start() async {
    try {
      final created = engine.call('doc_create', {
        'from': 'text',
        'text': 'PdfCraft Flutter shell\n\n'
            'This page was created through the automation tool table and rasterised by the '
            'engine\'s own render pool, handed over as premultiplied RGBA8.\n\n'
            'Pinch or scroll to zoom. Add a comment, then save.',
      });
      _doc = created['doc'] as int;
      _pageCount = created['pages'] as int? ?? 1;
      _loadPage();
      setState(() => _status = 'opened');
      _request();
      _pump = Timer.periodic(const Duration(milliseconds: 16), (_) => _drain());
    } on EngineError catch (e) {
      setState(() => _status = e.message);
    }
  }

  /// Ask for the pages around the current one at the current zoom.
  void _request() {
    final doc = _doc;
    if (doc == null) return;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    final scale = _zoom * dpr;
    final wanted = <TileRequest>[];
    for (var p = _current; p <= _pageCount && p < _current + 3; p++) {
      wanted.add(TileRequest(page: p, scale: scale, tag: scale.round()));
    }
    engine.queue(doc, wanted);
  }

  Future<void> _drain() async {
    final doc = _doc;
    if (doc == null || !mounted) return;
    final raster = await engine.poll(doc);
    if (raster == null || !mounted) return;
    setState(() {
      _pages[raster.page]?.dispose();
      _pages[raster.page] = raster.image;
    });
  }

  /// Page geometry and text lines for the current page.
  void _loadPage() {
    final doc = _doc;
    if (doc == null) return;
    try {
      final info = engine.call('doc_info', {'doc': doc});
      final pages = (info['pages'] as List?) ?? const [];
      if (_current - 1 < pages.length) {
        final p = pages[_current - 1] as Map<String, dynamic>;
        _pageSize = Size((p['width'] as num).toDouble(), (p['height'] as num).toDouble());
      }
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
  void selectAt(Offset local, Size rendered) {
    if (_lines.isEmpty || rendered.width <= 0) return;
    // Widget pixels -> view-space PDF points.
    final pt = Offset(
      local.dx / rendered.width * _pageSize.width,
      local.dy / rendered.height * _pageSize.height,
    );
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

  void goToPage(int page) {
    final target = page.clamp(1, _pageCount == 0 ? 1 : _pageCount);
    if (target == _current) return;
    setState(() => _current = target);
    _loadPage();
    _request();
  }

  /// Set the status line (used by tests to exercise long text).
  void showStatus(String text) => setState(() => _status = text);

  void setZoom(double z) {
    setState(() => _zoom = z.clamp(0.25, 8.0));
    _request();
  }

  @override
  Widget build(BuildContext context) {
    final img = _pages[_current];
    return Scaffold(
      appBar: AppBar(
        title: Text('PdfCraft${_dirty ? ' •' : ''}'),
        actions: [
          IconButton(onPressed: () => setZoom(_zoom / 1.25), icon: const Icon(Icons.zoom_out), tooltip: 'Zoom out'),
          Center(child: Text('${(_zoom * 100).round()}%')),
          IconButton(onPressed: () => setZoom(_zoom * 1.25), icon: const Icon(Icons.zoom_in), tooltip: 'Zoom in'),
          IconButton(onPressed: addComment, icon: const Icon(Icons.add_comment), tooltip: 'Add comment'),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: const Color(0xFF3A3A3C),
              child: Center(
                child: img == null
                    ? Text(_status, style: const TextStyle(color: Colors.white))
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          // Fit the page inside the viewport, preserving its aspect. The size
                          // computed here is the size actually laid out, and the hit-test uses
                          // the same number: a SizedBox asked for the image's natural width is
                          // silently clamped by the parent's constraints, which made taps land
                          // in the wrong place.
                          final aspect = _pageSize.width / _pageSize.height;
                          var w = constraints.maxWidth;
                          var h = w / aspect;
                          if (h > constraints.maxHeight) {
                            h = constraints.maxHeight;
                            w = h * aspect;
                          }
                          final rendered = Size(w, h);
                          return InteractiveViewer(
                            minScale: 1,
                            maxScale: 4,
                            child: Center(
                              child: GestureDetector(
                                onTapDown: (d) => selectAt(d.localPosition, rendered),
                                child: SizedBox(
                                  width: w,
                                  height: h,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      RawImage(image: img, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                                      CustomPaint(
                                        painter: _SelectionPainter(
                                          _selected >= 0 && _selected < _lines.length ? _lines[_selected].rect : null,
                                          _pageSize,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: Row(
              children: [
                IconButton(
                  onPressed: _current > 1 ? () => goToPage(_current - 1) : null,
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Previous page',
                ),
                Text('Page $_current of $_pageCount'),
                IconButton(
                  onPressed: _current < _pageCount ? () => goToPage(_current + 1) : null,
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Next page',
                ),
                const SizedBox(width: 8),
                // The status carries selected text, which is arbitrarily long: it has to flex
                // and clip, or the row overflows.
                Expanded(
                  child: Text(
                    _status,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
