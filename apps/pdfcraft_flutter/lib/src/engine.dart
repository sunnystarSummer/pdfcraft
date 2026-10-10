// A Dart-shaped view of the engine. Control is JSON through the automation tool table; pixels
// come back as borrowed native memory that this layer copies into a `ui.Image` and releases.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart' as pkgffi;

import 'ffi.dart';

/// A tool call that failed. The message is the engine's own, meant to be read.
class EngineError implements Exception {
  EngineError(this.message);
  final String message;
  @override
  String toString() => 'EngineError: $message';
}

/// One page raster, decoded and ready to paint.
class PageRaster {
  PageRaster(this.page, this.tag, this.image, this.renderMillis);
  final int page;
  final int tag;
  final ui.Image image;

  /// How long the engine's render pool spent rasterising this page. Useful for telling engine
  /// cost apart from transport and compositing cost.
  final int renderMillis;
}

class Engine {
  Engine._(this._native, this._ctx);

  final Native _native;
  final Pointer<Void> _ctx;
  final Pointer<CTile> _tile = pkgffi.calloc<CTile>();
  bool _closed = false;

  static Engine open({String? root}) {
    final native = Native.load();
    final ctx = root == null
        ? native.newEngine()
        : () {
            final bytes = utf8.encode(root);
            final buf = pkgffi.calloc<Uint8>(bytes.length);
            buf.asTypedList(bytes.length).setAll(0, bytes);
            final c = native.newWithRoot(buf, bytes.length);
            pkgffi.calloc.free(buf);
            return c;
          }();
    if (ctx == nullptr) throw EngineError('could not start the engine');
    return Engine._(native, ctx);
  }

  /// Run one automation tool. Throws [EngineError] when the tool fails.
  Map<String, dynamic> call(String tool, [Map<String, dynamic> args = const {}]) {
    _check();
    final request = utf8.encode(jsonEncode({'tool': tool, 'args': args}));
    final buf = pkgffi.calloc<Uint8>(request.length);
    buf.asTypedList(request.length).setAll(0, request);
    final outLen = pkgffi.calloc<Size>();
    String? text;
    try {
      final ptr = _native.call(_ctx, buf, request.length, outLen);
      if (ptr == nullptr) throw EngineError('$tool: the engine returned nothing');
      text = utf8.decode(ptr.asTypedList(outLen.value));
      _native.free(ptr, outLen.value);
    } finally {
      pkgffi.calloc.free(buf);
      pkgffi.calloc.free(outLen);
    }
    final reply = jsonDecode(text) as Map<String, dynamic>;
    if (reply['ok'] != true) throw EngineError('$tool: ${reply['error']}');
    final content = (reply['content'] as List).cast<Map<String, dynamic>>();
    if (content.isEmpty) return const {};
    return (content.first['json'] as Map<String, dynamic>?) ?? const {};
  }

  /// Replace the pending raster queue for `doc`. Most urgent first.
  void queue(int doc, List<TileRequest> reqs) {
    _check();
    if (reqs.isEmpty) {
      _native.queue(_ctx, doc, nullptr, 0);
      return;
    }
    final arr = pkgffi.calloc<CReq>(reqs.length);
    for (var i = 0; i < reqs.length; i++) {
      final r = reqs[i];
      arr[i]
        ..page = r.page
        ..scale = r.scale
        ..tileX = r.x
        ..tileY = r.y
        ..tileW = r.w
        ..tileH = r.h
        ..tag = r.tag
        ..tiled = r.tiled ? 1 : 0
        ..text = 0;
    }
    _native.queue(_ctx, doc, arr, reqs.length);
    pkgffi.calloc.free(arr);
  }

  /// Take one finished raster and decode it. Returns null when none is ready.
  ///
  /// The pixels are premultiplied RGBA8, which is exactly `PixelFormat.rgba8888`, so they go
  /// to the GPU untouched. `decodeImageFromPixels` is a native callback: inside a widget test
  /// it only completes under `tester.runAsync`.
  Future<PageRaster?> poll(int doc) async {
    _check();
    final ptr = _native.poll(_ctx, doc, _tile);
    if (ptr == nullptr) return null;
    final t = _tile.ref;
    final id = t.id;
    try {
      if (t.ok == 0) return null;
      // No copy: `asTypedList` is a view straight onto the engine's pixels, and the release in
      // the `finally` below runs only after the decode has completed, so the buffer stays alive
      // for exactly as long as it is read. Copying first cost a full 8 MB memcpy per tile at
      // 150 dpi plus the GC that followed.
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(ptr.asTypedList(t.len), t.width, t.height, ui.PixelFormat.rgba8888, completer.complete);
      return PageRaster(t.page, t.tag, await completer.future, t.millis);
    } finally {
      _native.release(_ctx, id);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _native.close(_ctx);
    pkgffi.calloc.free(_tile);
  }

  void _check() {
    if (_closed) throw EngineError('the engine is closed');
  }
}

class TileRequest {
  const TileRequest({
    required this.page,
    required this.scale,
    this.tag = 0,
    this.x = 0,
    this.y = 0,
    this.w = 0,
    this.h = 0,
    this.tiled = false,
  });
  final int page;
  final double scale;
  final int tag;
  final int x;
  final int y;
  final int w;
  final int h;
  final bool tiled;
}
