import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';
import 'package:slipreel_engine/rendering/wallpaper.dart';
import 'package:slipreel_engine/rendering/zoom_framing.dart';

import 'package:screen_recorder/ui/widgets/zoom/device_frame_composition.dart';

/// Mini-frame placement picker for a manual (`followCursor: false`)
/// zoom region.
///
/// Renders the *composed canvas* — wallpaper + padding + (optional)
/// device bezel + the screen frame — exactly as the editor renders it,
/// plus a draggable **viewport box** that shows what the magnify-in-place
/// zoom will frame. Drag the box to reposition the focal.
///
/// All coordinate math lives in canvas space (`canvasSize`). The affine
/// `videoRect` ↔ `videoSize` maps the emitted/incoming focal (which is
/// stored in *video* coordinates) to/from the canvas. The emitted focal
/// MAY fall outside `[0, videoSize]` (a placement over the padding) — that
/// is intended and is NOT clamped back to the video bounds.
///
/// Pure UI: no Riverpod, no async, no platform calls — everything arrives
/// via the constructor.
class ZoomPlacementPicker extends StatefulWidget {
  const ZoomPlacementPicker({
    super.key,
    required this.videoSize,
    required this.canvasSize,
    required this.videoRect,
    required this.wallpaperCategory,
    required this.wallpaperIndex,
    required this.zoomLevel,
    required this.rect,
    required this.onPreview,
    required this.onCommit,
    this.wallpaperSolidColor,
    this.deviceLayout,
    this.bezel,
    this.screenFrame,
  });

  /// Source video size in pixels (e.g. 1920×1080). Used for the affine
  /// transform and for the size of the emitted rect.
  final Size videoSize;

  /// Composed canvas size in pixels (wallpaper + padding + bezel + screen).
  /// The picker's coordinate space and the mini-frame aspect.
  final Size canvasSize;

  /// The video's rect within the composed canvas (canvas px).
  final Rect videoRect;

  /// Wallpaper category for [wallpaperDecoration]. Null when the project
  /// has no wallpaper — the render draws no wallpaper layer in that case
  /// (the dark editor canvas shows through), so the picker matches by
  /// showing a plain neutral backdrop instead of any wallpaper image.
  final String? wallpaperCategory;

  /// Wallpaper index for [wallpaperDecoration].
  final int wallpaperIndex;

  /// Custom solid fill color (only for the "Solid" category).
  final Color? wallpaperSolidColor;

  /// Device-frame layout (canvas px). Null for normal recordings.
  final DeviceFrameLayout? deviceLayout;

  /// Device bezel image. Null for normal recordings. Required (non-null)
  /// whenever [deviceLayout] is non-null.
  final ImageProvider? bezel;

  /// The extracted screen frame; may be null while still loading.
  final ui.Image? screenFrame;

  /// Current zoom strength; drives the viewport box size (`canvas / z`).
  final double zoomLevel;

  /// Current focal rect in video coordinates (only `rect.center` is read).
  final Rect rect;

  /// Fires on each drag update with the new focal rect (video coords).
  final ValueChanged<Rect> onPreview;

  /// Fires once on drag end with the final focal rect (video coords).
  final ValueChanged<Rect> onCommit;

  @override
  State<ZoomPlacementPicker> createState() => _ZoomPlacementPickerState();
}

class _ZoomPlacementPickerState extends State<ZoomPlacementPicker> {
  static const double _kMiniFrameMaxWidth = 280;

  /// Working focal rect (video coords) during an active drag. Null when no
  /// drag is in flight — UI falls back to widget.rect.
  Rect? _dragRect;

  /// Accumulated drag offset in screen (logical) pixels since pan start.
  Offset _accumulatedDelta = Offset.zero;

  /// Viewport-box center (canvas coords) at the moment the drag started.
  Offset? _panStartVc;

  /// The scale factor (mini-frame px per canvas px) used for the drag.
  double _panMiniScale = 1.0;

  Rect _currentRect() => _dragRect ?? widget.rect;

  // --- Framing: the single source of truth for the magnify-in-place law.
  // All viewport geometry (affine map, viewport box, drag inversion, clamp)
  // is delegated to ZoomFraming so the picker can never drift from the live
  // render / export math.

  ZoomFraming get _framing => ZoomFraming.device(
        videoSize: widget.videoSize,
        videoRect: widget.videoRect,
        canvasSize: widget.canvasSize,
      );

  /// True when the zoom is effectively 1× → the viewport fills the whole
  /// canvas, the focal is indeterminate, and drag must be disabled (the
  /// `1 - 1/z` factor is ~0, which would divide by zero on inversion).
  bool get _dragDisabled => (1.0 - 1.0 / widget.zoomLevel).abs() < 1e-6;

  /// The magnify-in-place viewport-box center in canvas coords for a given
  /// focal rect. Mirrors the render law for manual zooms.
  Offset _viewportCenter(Rect focalRect) {
    if (_dragDisabled) {
      return Offset(widget.canvasSize.width / 2, widget.canvasSize.height / 2);
    }
    return _framing.manualViewportRect(focalRect.center, widget.zoomLevel)
        .center;
  }

  /// The viewport box (canvas coords) for a given focal rect.
  Rect _viewportBox(Rect focalRect) {
    if (_dragDisabled) {
      return Rect.fromCenter(
        center:
            Offset(widget.canvasSize.width / 2, widget.canvasSize.height / 2),
        width: widget.canvasSize.width / widget.zoomLevel,
        height: widget.canvasSize.height / widget.zoomLevel,
      );
    }
    return _framing.manualViewportRect(focalRect.center, widget.zoomLevel);
  }

  /// Invert a (clamped) viewport-box center back to a focal rect in video
  /// coords. The emitted rect's center may lie outside `[0, videoSize]`.
  Rect _focalForVc(Offset vc) {
    final z = widget.zoomLevel;
    final center = _framing.manualFocalForViewportCenter(vc, z);
    // Only `center` is consumed downstream for manual placements — the manual
    // render reads `rect.center` and derives the viewport size itself from
    // `canvasSize / z`. The width/height here exist solely to give
    // `ZoomRegion.rect` a shape (and to round-trip serialization); they are NOT
    // used to size the viewport, so there is nothing to keep "in sync" with the
    // zoom level beyond this convenience value.
    return Rect.fromCenter(
      center: center,
      width: widget.videoSize.width / z,
      height: widget.videoSize.height / z,
    );
  }

  /// Clamp a viewport-box center so the box stays fully inside the canvas.
  Offset _clampVc(Offset vc) =>
      _framing.clampManualViewportCenter(vc, widget.zoomLevel);

  @override
  Widget build(BuildContext context) {
    final aspect = widget.canvasSize.width / widget.canvasSize.height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _kMiniFrameMaxWidth;
        final miniWidth = available.clamp(0.0, _kMiniFrameMaxWidth);
        final miniHeight = miniWidth / aspect;
        final miniScale = miniWidth / widget.canvasSize.width;

        // Viewport box (canvas coords) for the current focal, drawn at
        // *miniScale.
        final boxCanvas = _viewportBox(_currentRect());
        final boxMini = Rect.fromLTWH(
          boxCanvas.left * miniScale,
          boxCanvas.top * miniScale,
          boxCanvas.width * miniScale,
          boxCanvas.height * miniScale,
        );

        // The video's rect in mini-frame coords (for the normal path and
        // placeholder).
        final videoMini = Rect.fromLTWH(
          widget.videoRect.left * miniScale,
          widget.videoRect.top * miniScale,
          widget.videoRect.width * miniScale,
          widget.videoRect.height * miniScale,
        );

        // Align.topLeft lets the SizedBox be narrower than the tight parent
        // constraint (e.g. when parent forces 300px but we cap at 280).
        //
        // DecoratedBox + SizedBox.expand(key) + ClipRect (rather than a
        // Container with a border) avoids the implicit 1-px border padding
        // that would offset the Positioned children and break the mapping.
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
                      // 1. Backdrop fills the whole composed canvas. When the
                      //    project has a wallpaper, draw it; when it has none
                      //    (category == null) the render draws no wallpaper
                      //    layer and the dark editor canvas shows through, so
                      //    the picker shows a matching neutral backdrop (the
                      //    mini-frame's own dark fill) instead of any image.
                      if (widget.wallpaperCategory != null)
                        Positioned.fill(
                          child: Container(
                            key: const Key('zoom-placement-wallpaper'),
                            decoration: wallpaperDecoration(
                              widget.wallpaperCategory!,
                              widget.wallpaperIndex,
                              solidColor: widget.wallpaperSolidColor,
                            ),
                          ),
                        ),
                      // 2. The composition (device bezel + screen, or plain
                      //    screen frame in its video rect).
                      ..._buildComposition(miniScale, videoMini),
                      // 3. Spotlight dims everything outside the viewport box.
                      Positioned.fill(
                        child: CustomPaint(
                          key: const Key('zoom-placement-spotlight'),
                          painter: _SpotlightPainter(boxMini),
                        ),
                      ),
                      // 4. Viewport box + drag handle.
                      Positioned.fromRect(
                        rect: boxMini,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart:
                              _dragDisabled ? null : (_) => _onPanStart(miniScale),
                          onPanUpdate:
                              _dragDisabled ? null : _onPanUpdate,
                          onPanEnd: _dragDisabled ? null : _onPanEnd,
                          onPanCancel: _dragDisabled ? null : _onPanCancel,
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

  /// Builds the video composition layer (device bezel path, or normal path),
  /// scaled into the mini-frame. Falls back to a neutral placeholder when the
  /// screen frame is still loading.
  List<Widget> _buildComposition(double miniScale, Rect videoMini) {
    if (widget.deviceLayout != null && widget.bezel != null) {
      final layout = widget.deviceLayout!;
      final Widget videoChild = widget.screenFrame != null
          ? RawImage(
              image: widget.screenFrame,
              fit: BoxFit.cover,
            )
          : const ColoredBox(color: Color(0xFF11131A));
      // The layout is in canvas px; scale the whole composition by miniScale
      // so it maps to mini-frame px in lock-step with the box math.
      return [
        Positioned(
          left: 0,
          top: 0,
          width: widget.canvasSize.width,
          height: widget.canvasSize.height,
          child: Transform.scale(
            scale: miniScale,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: widget.canvasSize.width,
              height: widget.canvasSize.height,
              child: DeviceFrameComposition(
                key: const Key('zoom-placement-device'),
                layout: layout,
                video: videoChild,
                bezel: widget.bezel!,
              ),
            ),
          ),
        ),
      ];
    }
    // Normal recording: the screen frame fills its video rect.
    return [
      Positioned.fromRect(
        rect: videoMini,
        child: widget.screenFrame != null
            ? RawImage(
                key: const Key('zoom-placement-screen'),
                image: widget.screenFrame,
                fit: BoxFit.cover,
              )
            : const ColoredBox(
                key: Key('zoom-placement-screen-placeholder'),
                color: Color(0xFF11131A),
              ),
      ),
    ];
  }

  void _onPanStart(double miniScale) {
    setState(() {
      _panStartVc = _viewportCenter(widget.rect);
      _panMiniScale = miniScale;
      _accumulatedDelta = Offset.zero;
      _dragRect = widget.rect;
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    _accumulatedDelta += d.delta;
    // vc' = vc0 + accumulatedDelta / miniScale (canvas space), clamped so the
    // box stays inside the canvas. Using accumulated (not incremental) delta
    // avoids clamp drift when the box starts near an edge.
    final vc = _clampVc(_panStartVc! + _accumulatedDelta / _panMiniScale);
    final newRect = _focalForVc(vc);
    setState(() => _dragRect = newRect);
    widget.onPreview(newRect);
  }

  void _onPanEnd(DragEndDetails _) {
    final committed = _dragRect ?? widget.rect;
    setState(() {
      _dragRect = null;
      _panStartVc = null;
      _accumulatedDelta = Offset.zero;
    });
    widget.onCommit(committed);
  }

  void _onPanCancel() {
    setState(() {
      _dragRect = null;
      _panStartVc = null;
      _accumulatedDelta = Offset.zero;
    });
  }
}

/// Dims everything outside [selection] (a spotlight) so the framed region
/// stays bright. Uses a clear-blend punch-out over a translucent scrim.
class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter(this.selection);

  final Rect selection;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    canvas.saveLayer(full, Paint());
    canvas.drawRect(full, Paint()..color = Colors.black54);
    canvas.drawRect(selection, Paint()..blendMode = BlendMode.clear);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => old.selection != selection;
}
