import 'package:flutter/material.dart';

/// Widget for selecting zoom regions via tap or drag
class ZoomSelector extends StatefulWidget {
  final bool enabled;
  final Size videoSize;
  final ValueChanged<Rect> onRegionSelected;
  final Widget child;
  final double defaultRegionSize;

  const ZoomSelector({
    super.key,
    required this.enabled,
    required this.videoSize,
    required this.onRegionSelected,
    required this.child,
    this.defaultRegionSize = 200.0,
  });

  @override
  State<ZoomSelector> createState() => _ZoomSelectorState();
}

class _ZoomSelectorState extends State<ZoomSelector> {
  Rect? _currentRect;
  Offset? _dragStart;
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }

    return GestureDetector(
      onTapDown: (details) {
        if (!_isDragging) {
          _handleTap(details.localPosition);
        }
      },
      onPanStart: (details) {
        _dragStart = details.localPosition;
        _isDragging = true;
        setState(() {
          _currentRect = Rect.fromLTWH(
            details.localPosition.dx,
            details.localPosition.dy,
            0,
            0,
          );
        });
      },
      onPanUpdate: (details) {
        if (_dragStart != null) {
          final start = _dragStart!;
          final current = details.localPosition;

          setState(() {
            _currentRect = Rect.fromPoints(start, current);
          });
        }
      },
      onPanEnd: (details) {
        if (_currentRect != null && _currentRect!.width > 10 && _currentRect!.height > 10) {
          widget.onRegionSelected(_normalizeRect(_currentRect!));
        }
        setState(() {
          _currentRect = null;
          _dragStart = null;
          _isDragging = false;
        });
      },
      child: Stack(
        children: [
          widget.child,
          if (_currentRect != null)
            CustomPaint(
              size: widget.videoSize,
              painter: _ZoomSelectorPainter(_currentRect!),
            ),
        ],
      ),
    );
  }

  void _handleTap(Offset position) {
    // Create default sized region centered on tap
    final halfSize = widget.defaultRegionSize / 2;
    final rect = Rect.fromLTWH(
      (position.dx - halfSize).clamp(0, widget.videoSize.width - widget.defaultRegionSize),
      (position.dy - halfSize).clamp(0, widget.videoSize.height - widget.defaultRegionSize),
      widget.defaultRegionSize,
      widget.defaultRegionSize,
    );

    widget.onRegionSelected(rect);
  }

  Rect _normalizeRect(Rect rect) {
    // Ensure rect has positive width/height
    final left = rect.left < rect.right ? rect.left : rect.right;
    final top = rect.top < rect.bottom ? rect.top : rect.bottom;
    final right = rect.left < rect.right ? rect.right : rect.left;
    final bottom = rect.top < rect.bottom ? rect.bottom : rect.top;

    return Rect.fromLTRB(
      left.clamp(0, widget.videoSize.width),
      top.clamp(0, widget.videoSize.height),
      right.clamp(0, widget.videoSize.width),
      bottom.clamp(0, widget.videoSize.height),
    );
  }
}

class _ZoomSelectorPainter extends CustomPainter {
  final Rect rect;

  _ZoomSelectorPainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    // Draw semi-transparent overlay
    final overlayPaint = Paint()
      ..color = const Color(0xFF6C63FF).withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;

    canvas.drawRect(rect, overlayPaint);

    // Draw border
    final borderPaint = Paint()
      ..color = const Color(0xFF6C63FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawRect(rect, borderPaint);

    // Draw corner handles
    final handlePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    const handleSize = 8.0;
    final corners = [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ];

    for (final corner in corners) {
      canvas.drawCircle(corner, handleSize, handlePaint);
    }
  }

  @override
  bool shouldRepaint(_ZoomSelectorPainter oldDelegate) {
    return oldDelegate.rect != rect;
  }
}
