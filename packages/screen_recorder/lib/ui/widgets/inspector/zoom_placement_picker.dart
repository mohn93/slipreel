import 'package:flutter/material.dart';

/// Mini-frame placement picker for a manual (`followCursor: false`)
/// zoom region. Renders a small box whose aspect ratio matches the
/// video; inside, a smaller rectangle shows the framing area
/// (`videoSize / zoomLevel`). Pan the inner rect to move the focal.
///
/// Pure UI: no Riverpod, no async, no platform calls.
class ZoomPlacementPicker extends StatefulWidget {
  const ZoomPlacementPicker({
    super.key,
    required this.videoSize,
    required this.rect,
    required this.zoomLevel,
    required this.onPreview,
    required this.onCommit,
  });

  /// Source video size in pixels (e.g. 1920×1080).
  final Size videoSize;

  /// Current focal rect in video coordinates.
  final Rect rect;

  /// Current zoom strength. Used to derive the inner rect's size.
  final double zoomLevel;

  /// Fires on each pan update with the new rect (video coords, clamped).
  final ValueChanged<Rect> onPreview;

  /// Fires once on pan end with the final rect (video coords, clamped).
  final ValueChanged<Rect> onCommit;

  @override
  State<ZoomPlacementPicker> createState() => _ZoomPlacementPickerState();
}

class _ZoomPlacementPickerState extends State<ZoomPlacementPicker> {
  static const double _kMiniFrameMaxWidth = 280;

  /// Working rect in video coords during an active drag. Null when no
  /// drag is in flight — UI falls back to widget.rect.
  Rect? _dragRect;

  /// Accumulated drag offset in screen (logical) pixels since pan start.
  Offset _accumulatedDelta = Offset.zero;

  /// Video-coord center at the moment the pan gesture started.
  Offset? _panStartCenter;

  /// The scale factor (mini-frame px per video px) used for the current drag.
  double _panScale = 1.0;

  Rect _currentRect() => _dragRect ?? widget.rect;

  /// Size of the framed inner rect in video coordinates.
  Size _innerSize() => Size(
        widget.videoSize.width / widget.zoomLevel,
        widget.videoSize.height / widget.zoomLevel,
      );

  /// Clamp a center so the inner rect stays fully inside videoSize.
  Offset _clampCenter(Offset c, Size inner) {
    final halfW = inner.width / 2;
    final halfH = inner.height / 2;
    return Offset(
      c.dx.clamp(halfW, widget.videoSize.width - halfW),
      c.dy.clamp(halfH, widget.videoSize.height - halfH),
    );
  }

  @override
  Widget build(BuildContext context) {
    final aspect = widget.videoSize.width / widget.videoSize.height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _kMiniFrameMaxWidth;
        final miniWidth = available.clamp(0.0, _kMiniFrameMaxWidth);
        final miniHeight = miniWidth / aspect;
        final scale = miniWidth / widget.videoSize.width;

        final inner = _innerSize();
        final innerW = inner.width * scale;
        final innerH = inner.height * scale;

        final cur = _currentRect();
        // Position of inner rect's top-left in mini-frame coordinates.
        final innerLeft = (cur.center.dx - inner.width / 2) * scale;
        final innerTop = (cur.center.dy - inner.height / 2) * scale;

        // Align.topLeft lets the SizedBox be narrower than the tight
        // parent constraint (e.g. when parent forces 300px but we cap at 280).
        //
        // DecoratedBox + SizedBox.expand(key) + ClipRect instead of a plain
        // Container(decoration, child) avoids the implicit 1-px border padding
        // that Container adds when BoxDecoration has a border — which would
        // offset the Positioned children and break the coordinate mapping.
        return Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: miniWidth,
            height: miniHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A22),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF2A2A35)),
              ),
              child: SizedBox.expand(
                key: const Key('zoom-placement-mini-frame'),
                child: ClipRect(
                  child: Stack(
                    children: [
                      Positioned(
                        left: innerLeft,
                        top: innerTop,
                        width: innerW,
                        height: innerH,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) {
                            setState(() {
                              _panStartCenter = widget.rect.center;
                              _panScale = scale;
                              _accumulatedDelta = Offset.zero;
                              _dragRect = widget.rect;
                            });
                          },
                          onPanUpdate: (d) {
                            _accumulatedDelta += d.delta;
                            final origin = _panStartCenter!;
                            // Compute new center from origin + total drag in video coords.
                            // Using accumulated delta (not incremental) avoids clamping
                            // drift when the initial rect is near the boundary.
                            final rawDelta = _accumulatedDelta / _panScale;
                            final innerSz = _innerSize();
                            final newCenter =
                                _clampCenter(origin + rawDelta, innerSz);
                            final newRect = Rect.fromCenter(
                                center: newCenter,
                                width: innerSz.width,
                                height: innerSz.height);
                            setState(() => _dragRect = newRect);
                            widget.onPreview(newRect);
                          },
                          onPanEnd: (_) {
                            final committed = _dragRect ?? widget.rect;
                            setState(() {
                              _dragRect = null;
                              _panStartCenter = null;
                              _accumulatedDelta = Offset.zero;
                            });
                            widget.onCommit(committed);
                          },
                          onPanCancel: () {
                            setState(() {
                              _dragRect = null;
                              _panStartCenter = null;
                              _accumulatedDelta = Offset.zero;
                            });
                          },
                          child: Container(
                            key: const Key('zoom-placement-inner-rect'),
                            decoration: BoxDecoration(
                              color: const Color(0x33A78BFA),
                              border: Border.all(
                                  color: const Color(0xFFA78BFA), width: 1.5),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
