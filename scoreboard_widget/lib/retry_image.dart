import 'package:flutter/material.dart';

class RetryNetworkImage extends StatefulWidget {
  final String? imageUrl;
  final String fallbackAsset;
  final double width;
  final double height;
  final int maxRetries;
  final Duration retryDelay;

  const RetryNetworkImage({
    super.key,
    required this.imageUrl,
    required this.fallbackAsset,
    required this.width,
    required this.height,
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 1),
  });

  @override
  State<RetryNetworkImage> createState() => _RetryNetworkImageState();
}

class _RetryNetworkImageState extends State<RetryNetworkImage> {
  int _retryCount = 0;
  String? _currentImageUrl;

  @override
  void initState() {
    super.initState();
    _currentImageUrl = widget.imageUrl;
  }

  void _retryLoadImage() {
    if (_retryCount < widget.maxRetries) {
      setState(() {
        _retryCount++;
        _currentImageUrl = '${widget.imageUrl}?retry=$_retryCount&t=${DateTime.now().millisecondsSinceEpoch}';
      });
    }
  }

  @override
  void didUpdateWidget(covariant RetryNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _retryCount = 0;
      _currentImageUrl = widget.imageUrl;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(15),
      child: (_currentImageUrl != null && _currentImageUrl!.isNotEmpty)
          ? Image.network(
              _currentImageUrl!,
              width: widget.width,
              height: widget.height,
              errorBuilder: (context, error, stackTrace) {
                if (_retryCount < widget.maxRetries) {
                  // Programar reintento después del delay
                  Future.delayed(widget.retryDelay, () {
                    if (mounted) _retryLoadImage();
                  });
                  
                  // Mostrar loading mientras reintenta
                  return Container(
                    width: widget.width,
                    height: widget.height,
                    color: Colors.grey[200],
                    child: const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                } else {
                  // Todos los reintentos fallaron, mostrar asset
                  return Image.asset(
                    widget.fallbackAsset,
                    width: widget.width,
                    height: widget.height,
                  );
                }
              },
            )
          : Image.asset(
              widget.fallbackAsset,
              width: widget.width,
              height: widget.height,
            ),
    );
  }
}