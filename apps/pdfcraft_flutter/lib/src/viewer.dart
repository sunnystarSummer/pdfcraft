import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'engine.dart';

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
    _request();
  }

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
                    : InteractiveViewer(
                        minScale: 1,
                        maxScale: 4,
                        child: RawImage(
                          image: img,
                          width: img.width / (MediaQuery.devicePixelRatioOf(context) * _zoom) * _zoom,
                          filterQuality: FilterQuality.medium,
                        ),
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
                const Spacer(),
                Text(_status),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
