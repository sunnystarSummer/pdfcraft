// Performance measurement against the real engine and the real viewer path, not a spike.
//
//   flutter run -t lib/bench.dart -d macos --release
//
// Prints to stderr and exits. Two numbers matter, and they are the ones Gate 2 asks for:
// tile-to-glass (request -> on screen) and the frame cost of scrolling a large document.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'src/engine.dart';

/// Enough text to paginate into a large document, shaped like the fixture the egui perf test
/// uses (`crates/ui-egui/tests/perf.rs`): plain lines with words to lay out.
String corpus(int pages) {
  final b = StringBuffer();
  for (var p = 0; p < pages; p++) {
    for (var l = 0; l < 44; l++) {
      b.writeln('Page ${p + 1} line $l with some words to lay out and measure.');
    }
  }
  return b.toString();
}

void main() => runApp(const _Bench());

class _Bench extends StatefulWidget {
  const _Bench();
  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  late final Engine _engine;
  final Map<int, ui.Image> _cache = {};
  final List<int> _frames = [];
  bool _recording = false;
  ui.Image? _shown;
  String _status = 'starting';

  @override
  void initState() {
    super.initState();
    _engine = Engine.open();
    SchedulerBinding.instance.addTimingsCallback((list) {
      if (!_recording) return;
      for (final t in list) {
        _frames.add(t.totalSpan.inMicroseconds);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _nextFrame() {
    final done = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => done.complete());
    return done.future;
  }

  Future<PageRaster?> _drain(int doc) => _engine.poll(doc);

  Future<void> _run() async {
    const wanted = 500;
    final created = _engine.call('doc_create', {'from': 'text', 'text': corpus(wanted)});
    final doc = created['doc'] as int;
    final pages = created['pages'] as int;
    stderr.writeln('document: $pages pages, ${Platform.numberOfProcessors} cpus');

    // ---- tile-to-glass: request one page, wait until it is painted ----
    final glass = <int>[];
    for (var i = 0; i < 24; i++) {
      final page = 10 + i;
      final sw = Stopwatch()..start();
      _engine.queue(doc, [TileRequest(page: page, scale: 2.0833, tag: page)]);
      PageRaster? got;
      while (got == null) {
        got = await _drain(doc);
        if (got == null) await Future<void>.delayed(const Duration(microseconds: 500));
      }
      setState(() => _shown = got!.image);
      await _nextFrame();
      sw.stop();
      glass.add(sw.elapsedMicroseconds);
      got.image.dispose();
    }
    glass.sort();
    stderr.writeln('TILE-TO-GLASS  p50 ${_ms(glass, 50)}  p95 ${_ms(glass, 95)}');

    // ---- sustained scroll ----
    setState(() => _status = 'scroll');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _frames.clear();
    _recording = true;

    const frames = 200;
    for (var f = 0; f < frames; f++) {
      final target = ((f * 5) ~/ 2) % pages + 1;
      final want = [for (var d = 0; d < 4; d++) target + d].where((p) => p <= pages && !_cache.containsKey(p)).toList();
      if (want.isNotEmpty) {
        _engine.queue(doc, [for (final p in want) TileRequest(page: p, scale: 2.0833, tag: p)]);
      }
      for (var k = 0; k < 3; k++) {
        final r = await _drain(doc);
        if (r != null) {
          _cache[r.page]?.dispose();
          _cache[r.page] = r.image;
        }
      }
      if (_cache.length > 40) {
        for (final key in _cache.keys.take(_cache.length - 40).toList()) {
          _cache.remove(key)?.dispose();
        }
      }
      setState(() => _shown = _cache[target]);
      await _nextFrame();
    }
    _recording = false;

    _frames.sort();
    if (_frames.isNotEmpty) {
      final avg = _frames.reduce((a, b) => a + b) / _frames.length / 1000.0;
      final over = _frames.where((m) => m > 16700).length;
      stderr.writeln('SCROLL         frames ${_frames.length}  avg ${avg.toStringAsFixed(2)} ms  '
          'p50 ${_ms(_frames, 50)}  p95 ${_ms(_frames, 95)}');
      stderr.writeln('OVER BUDGET    $over/${_frames.length} frames above 16.7 ms '
          '(${(over * 100 / _frames.length).toStringAsFixed(1)}%)');
    }
    stderr.writeln('DONE');
    exit(0);
  }

  String _ms(List<int> xs, int pct) => '${(xs[(xs.length * pct / 100).clamp(0, xs.length - 1).toInt()] / 1000.0).toStringAsFixed(2)} ms';

  @override
  Widget build(BuildContext context) {
    final img = _shown;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF3A3A3C),
        body: Center(
          child: img == null
              ? Text(_status, style: const TextStyle(color: Colors.white))
              : RawImage(image: img, filterQuality: FilterQuality.medium),
        ),
      ),
    );
  }
}
