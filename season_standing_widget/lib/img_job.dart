import 'dart:async';
import 'package:flutter/material.dart';
import 'package:collection/collection.dart';

class _ImgJob {
  final BuildContext context;
  final String url;
  final int priority;
  final VoidCallback onReady;
  bool cancelled = false;
  _ImgJob(this.context, this.url, this.priority, this.onReady);
}

class ImageLoadScheduler {
  static final ImageLoadScheduler I = ImageLoadScheduler._();
  ImageLoadScheduler._();

  final HeapPriorityQueue<_ImgJob> _queue = HeapPriorityQueue<_ImgJob>(
    (a, b) => a.priority.compareTo(b.priority),
  );

  final Set<String> _loading = <String>{};
  final Set<String> _ready   = <String>{};

  int maxConcurrent = 6;
  int targetPx = 105; // Aumentado para soportar pantallas 3x (35 * 3)

  void configureGlobalCache({int entries = 80, int bytesMB = 32}) {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSize = entries;
    cache.maximumSizeBytes = bytesMB << 20;
  }

  bool isReady(String url) => _ready.contains(url);

  void clearAll() {
    _queue.clear();
    _loading.clear();
    _ready.clear();
  }

  void markStale(String url) {
    _ready.remove(url);
  }

  void request(BuildContext ctx, String url, int priority, VoidCallback onReady) {
    if (url.isEmpty) { onReady(); return; }
    if (_ready.contains(url)) { onReady(); return; }

    _queue.add(_ImgJob(ctx, url, priority, onReady));
    _pump();
  }

  Timer? _pumpTimer;

  void _pump() {
    _pumpTimer ??= Timer(const Duration(milliseconds: 16), () {
      _pumpTimer = null;

      while (_loading.length < maxConcurrent && _queue.isNotEmpty) {
        final job = _queue.removeFirst();
        if (job.cancelled) continue;
        if (_ready.contains(job.url)) { job.onReady(); continue; }
        if (_loading.contains(job.url)) continue;

        _loading.add(job.url);

        final provider = ResizeImage(
          NetworkImage(job.url),
          width:  targetPx,
          height: targetPx,
        );

        precacheImage(provider, job.context, onError: (_, __) {}).then((_) {
          _ready.add(job.url);
          _loading.remove(job.url);
          job.onReady();
          _pump();
        }).catchError((_) {
          _loading.remove(job.url);
          job.onReady();
          _pump();
        });
      }
    });
  }
}

class QueuedLogo extends StatefulWidget {
  final String url;
  final double size;
  final int priority;
  const QueuedLogo({
    super.key,
    required this.url,
    this.size = 20,
    required this.priority,
  });

  @override
  State<QueuedLogo> createState() => _QueuedLogoState();
}

class _QueuedLogoState extends State<QueuedLogo> {
  bool _ready = false;

  void _enqueue() {
    if (widget.url.isEmpty) return;
    _ready = ImageLoadScheduler.I.isReady(widget.url);
    if (!_ready) {
      ImageLoadScheduler.I.request(context, widget.url, widget.priority, () {
        if (mounted) setState(() => _ready = true);
      });
    } else {
      if (mounted) setState(() => _ready = true);
    }
  }

  @override
  void initState() {
    super.initState();
    _enqueue();
  }

  @override
  void didUpdateWidget(covariant QueuedLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      ImageLoadScheduler.I.markStale(oldWidget.url);
      _ready = false;
      _enqueue();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || widget.url.isEmpty) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const Icon(Icons.image, size: 16, color: Colors.grey),
      );
    }
    
    // Obtener el devicePixelRatio para calcular el tamaño correcto
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    final physicalSize = (widget.size * pixelRatio).ceil();
    
    final provider = ResizeImage(
      NetworkImage(widget.url),
      width:  physicalSize,
      height: physicalSize,
    );

    return Image(
      image: provider,
      width: widget.size,
      height: widget.size,
      gaplessPlayback: true,
      filterQuality: FilterQuality.high,
      isAntiAlias: true,
      errorBuilder: (_, __, ___) => SizedBox(
        width: widget.size, height: widget.size,
        child: const Icon(Icons.image, size: 16),
      ),
    );
  }
}