import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'cursor_image_cache.dart';

/// Glyph rendering for non-arrow cursor states (I-beam, pointing hand,
/// resize variants, etc.).
///
/// Each shape is hand-coded as a closed polygon in a small design
/// grid (height = 14 design units, matching the macOS arrow body's
/// height). The renderer rebuilds the path scaled to [diameter] each
/// frame and draws a thick white stroke underneath the black fill so
/// the cursor reads as "macOS-style" — black body, white halo —
/// without needing a separate inflated halo polygon per shape.
///
/// Arrow rendering lives in cursor_glyph.dart (the SVG-accurate
/// dual-path version); this file handles every other state.

/// Returns whether [state] is the default arrow (handled by the
/// existing arrow renderer in cursor_glyph.dart). Anything else is
/// dispatched here.
bool isArrowState(CursorState state) => state == CursorState.arrow;

/// Renders a non-arrow cursor [state] at [position] with the given
/// [diameter] (height of the bounding box in canvas pixels). The
/// hot-spot of each glyph aligns with [position] — that's the click
/// point the OS records, so callers can pass the cursor recording
/// position unchanged.
void paintStateGlyph(
  Canvas canvas, {
  required CursorState state,
  required Offset position,
  required double diameter,
}) {
  // Prefer the OS-accurate bitmap if [CursorImageCache.load] has
  // populated one for this state. Falls through to the hand-coded
  // polygon path only when the cache is empty (still loading, or
  // the host platform doesn't expose its cursor bitmaps).
  final cached = CursorImageCache.imageFor(state);
  if (cached != null) {
    _paintStockCursorImage(canvas, position, diameter, cached);
    return;
  }
  switch (state) {
    case CursorState.iBeam:
      _paintGlyph(canvas, position, diameter, _kIBeam);
      break;
    case CursorState.pointingHand:
      _paintGlyph(canvas, position, diameter, _kPointingHand);
      break;
    case CursorState.crosshair:
      _paintGlyph(canvas, position, diameter, _kCrosshair);
      break;
    case CursorState.resizeNS:
      _paintGlyph(canvas, position, diameter, _kResizeNS);
      break;
    case CursorState.resizeEW:
      _paintGlyph(canvas, position, diameter, _kResizeEW);
      break;
    case CursorState.resizeNESW:
      _paintGlyph(canvas, position, diameter, _kResizeNESW);
      break;
    case CursorState.resizeNWSE:
      _paintGlyph(canvas, position, diameter, _kResizeNWSE);
      break;
    case CursorState.notAllowed:
      _paintNotAllowed(canvas, position, diameter);
      break;
    case CursorState.openHand:
      _paintGlyph(canvas, position, diameter, _kOpenHand);
      break;
    case CursorState.closedHand:
      _paintGlyph(canvas, position, diameter, _kClosedHand);
      break;
    case CursorState.arrow:
      throw StateError('arrow handled by cursor_glyph.dart');
  }
}

/// Polygon-based glyph data: a single closed path in design units,
/// plus the hot-spot in those same units (the OS-reported cursor
/// position aligns with this point). [designHeight] is the height
/// of the bounding box used to scale the design grid to canvas px.
class _GlyphSpec {
  final List<Offset> vertices;
  final Offset hotSpot;
  final double designHeight;
  // Halo stroke width as a fraction of designHeight. Larger values
  // make the white halo thicker; tuned per shape so simple thick
  // shapes (resize arrows) keep a slim halo and thin shapes (I-beam)
  // get a more visible one.
  final double haloFraction;
  const _GlyphSpec({
    required this.vertices,
    required this.hotSpot,
    required this.designHeight,
    this.haloFraction = 0.10,
  });
}

/// Blits a `CachedCursorImage` so the cursor's hot-spot aligns with
/// [position] and the bitmap's height equals [diameter]. Uses
/// `FilterQuality.medium` so down-scaled cursors stay crisp without
/// the muddiness of `low` or the overhead of `high`.
void _paintStockCursorImage(
  Canvas canvas,
  Offset position,
  double diameter,
  CachedCursorImage cached,
) {
  // Match the polygon path's reference axis: scale so the image's
  // logical height equals the user's chosen cursor diameter.
  final scale = diameter / cached.imageHeight;
  final destWidth = cached.imageWidth * scale;
  final destHeight = cached.imageHeight * scale;
  // Anchor the destination rect so (hotSpot × scale) lands on
  // `position` — the recorded cursor coordinate is the click point,
  // and that's where the cursor's hot-spot should sit.
  final dstLeft = position.dx - cached.hotSpotX * scale;
  final dstTop = position.dy - cached.hotSpotY * scale;
  canvas.drawImageRect(
    cached.image,
    Rect.fromLTWH(
      0,
      0,
      cached.image.width.toDouble(),
      cached.image.height.toDouble(),
    ),
    Rect.fromLTWH(dstLeft, dstTop, destWidth, destHeight),
    Paint()..filterQuality = ui.FilterQuality.medium,
  );
}

void _paintGlyph(Canvas canvas, Offset position, double diameter, _GlyphSpec spec) {
  final scale = diameter / spec.designHeight;
  final path = Path();
  for (var i = 0; i < spec.vertices.length; i++) {
    final v = spec.vertices[i];
    final p = Offset(
      position.dx + (v.dx - spec.hotSpot.dx) * scale,
      position.dy + (v.dy - spec.hotSpot.dy) * scale,
    );
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  path.close();

  final haloWidth = diameter * spec.haloFraction;
  // Halo first (white stroke). Round joins keep sharp polygon corners
  // from spiking out on diagonal arrows.
  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white
      ..strokeWidth = haloWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round,
  );
  // Body (black fill on top).
  canvas.drawPath(path, Paint()..color = Colors.black);
}

// =====================================================================
// I-beam (text edit cursor)
// =====================================================================
//
// Vertical line with horizontal serifs at top and bottom. Hot-spot at
// the geometric center of the bar so the click point lands on the
// caret position the user is hovering over.
const _GlyphSpec _kIBeam = _GlyphSpec(
  vertices: [
    Offset(-3, -7),  // top serif top-left
    Offset(3, -7),   // top serif top-right
    Offset(3, -6),   // top serif bottom-right
    Offset(0.7, -6), // right side of vertical bar (top)
    Offset(0.7, 6),  // right side of vertical bar (bottom)
    Offset(3, 6),    // bottom serif top-right
    Offset(3, 7),    // bottom serif bottom-right
    Offset(-3, 7),   // bottom serif bottom-left
    Offset(-3, 6),   // bottom serif top-left
    Offset(-0.7, 6), // left side of vertical bar (bottom)
    Offset(-0.7, -6),// left side of vertical bar (top)
    Offset(-3, -6),  // top serif bottom-left
  ],
  hotSpot: Offset.zero,
  designHeight: 14,
  haloFraction: 0.14,
);

// =====================================================================
// Pointing hand (links / clickable targets)
// =====================================================================
//
// Highly simplified hand: extended index finger with a fist below.
// macOS's actual handpointing.svg is 100+ Bezier vertices; this
// approximation reads as "pointing hand" at typical cursor sizes.
// Hot-spot at the fingertip (top of the index finger) — that's where
// the OS expects clicks to register.
const _GlyphSpec _kPointingHand = _GlyphSpec(
  vertices: [
    // Index finger (vertical rectangle at top).
    Offset(-1.2, 0),    // fingertip-left (hot-spot at center, this is left of tip)
    Offset(-1.2, 5),    // base of finger left
    // Hand body curves out from base of finger.
    Offset(-3.2, 5),    // left edge of hand top
    Offset(-3.2, 11),   // left edge of hand bottom
    Offset(-2.0, 12.5), // bottom-left wrist
    Offset(2.5, 12.5),  // bottom-right wrist
    Offset(3.5, 11),    // right edge of hand bottom
    Offset(3.5, 5),     // right edge of hand top
    // Knuckles silhouette on the right.
    Offset(2.0, 5),
    Offset(2.0, 3),     // tip of middle/ring/little knuckles
    Offset(1.2, 3),
    Offset(1.2, 0),     // back to fingertip-right
  ],
  hotSpot: Offset(0, 0),
  designHeight: 13,
  haloFraction: 0.10,
);

// =====================================================================
// Crosshair (precision selection)
// =====================================================================
//
// Twelve-vertex "+" outline matching cross.svg. Hot-spot at the
// crosshair's center so the click registers exactly where the
// horizontal and vertical strokes intersect.
const _GlyphSpec _kCrosshair = _GlyphSpec(
  vertices: [
    Offset(6.5, 0),    // top of vertical arm, right edge
    Offset(6.5, 6.0),  // inner top-right corner
    Offset(13, 6.0),   // right of horizontal arm, top edge
    Offset(13, 7.0),   // right of horizontal arm, bottom edge
    Offset(6.5, 7.0),  // inner bottom-right corner
    Offset(6.5, 13),   // bottom of vertical arm, right edge
    Offset(5.5, 13),   // bottom of vertical arm, left edge
    Offset(5.5, 7.0),  // inner bottom-left corner
    Offset(0, 7.0),    // left of horizontal arm, bottom edge
    Offset(0, 6.0),    // left of horizontal arm, top edge
    Offset(5.5, 6.0),  // inner top-left corner
    Offset(5.5, 0),    // top of vertical arm, left edge
  ],
  hotSpot: Offset(6, 6.5),
  designHeight: 13,
  haloFraction: 0.12,
);

// =====================================================================
// Resize cursors
// =====================================================================
//
// Double-headed arrows. Hot-spot is the center of the cursor (the
// resize handle the user is hovering over). Each shape traces the
// double-arrow outline as a single closed polygon.

// Vertical (north/south) resize.
const _GlyphSpec _kResizeNS = _GlyphSpec(
  vertices: [
    Offset(0, -7),       // top tip
    Offset(3, -3.5),     // top arrowhead, right
    Offset(1, -3.5),     // base of top arrowhead, right side of bar
    Offset(1, 3.5),      // top of bottom arrowhead, right side of bar
    Offset(3, 3.5),      // bottom arrowhead, right
    Offset(0, 7),        // bottom tip
    Offset(-3, 3.5),     // bottom arrowhead, left
    Offset(-1, 3.5),     // bottom of top arrowhead, left side of bar
    Offset(-1, -3.5),    // top of top arrowhead, left side of bar
    Offset(-3, -3.5),    // top arrowhead, left
  ],
  hotSpot: Offset.zero,
  designHeight: 14,
  haloFraction: 0.12,
);

// Horizontal (east/west) resize.
const _GlyphSpec _kResizeEW = _GlyphSpec(
  vertices: [
    Offset(-7, 0),
    Offset(-3.5, 3),
    Offset(-3.5, 1),
    Offset(3.5, 1),
    Offset(3.5, 3),
    Offset(7, 0),
    Offset(3.5, -3),
    Offset(3.5, -1),
    Offset(-3.5, -1),
    Offset(-3.5, -3),
  ],
  hotSpot: Offset.zero,
  designHeight: 6,
  haloFraction: 0.20,
);

// Diagonal NE-SW resize (↗↙).
const _GlyphSpec _kResizeNESW = _GlyphSpec(
  vertices: [
    // Top-right arrowhead: tip at (5, -5), base spans across the bar.
    Offset(5, -5),
    Offset(5, -1.5),
    Offset(2.8, 0.7),
    Offset(0.7, 2.8),
    Offset(-1.5, 5),
    Offset(-5, 5),
    Offset(-5, 1.5),
    Offset(-2.8, -0.7),
    Offset(-0.7, -2.8),
    Offset(1.5, -5),
  ],
  hotSpot: Offset.zero,
  designHeight: 12,
  haloFraction: 0.16,
);

// Diagonal NW-SE resize (↘↖).
const _GlyphSpec _kResizeNWSE = _GlyphSpec(
  vertices: [
    Offset(-5, -5),
    Offset(-1.5, -5),
    Offset(0.7, -2.8),
    Offset(2.8, -0.7),
    Offset(5, 1.5),
    Offset(5, 5),
    Offset(1.5, 5),
    Offset(-0.7, 2.8),
    Offset(-2.8, 0.7),
    Offset(-5, -1.5),
  ],
  hotSpot: Offset.zero,
  designHeight: 12,
  haloFraction: 0.16,
);

// =====================================================================
// Open / closed hand
// =====================================================================
//
// Both hand cursors are simplified: a roughly hand-shaped outline.
// The open hand has a slightly wider, flatter silhouette (fingers
// spread); the closed hand is more compact (fingers curled). These
// won't match macOS pixel-for-pixel but are clearly distinguishable.

const _GlyphSpec _kOpenHand = _GlyphSpec(
  vertices: [
    // Top of palm with four "fingertip" bumps.
    Offset(-5, -2),
    Offset(-4, -6),
    Offset(-2.5, -6),
    Offset(-2, -2),
    Offset(-1, -2),
    Offset(-0.7, -7),
    Offset(0.7, -7),
    Offset(1, -2),
    Offset(2, -2),
    Offset(2.5, -6),
    Offset(4, -6),
    Offset(4.5, -2),
    // Right side of palm down to wrist.
    Offset(5, 4),
    Offset(3, 7),
    Offset(-3, 7),
    Offset(-5, 4),
  ],
  hotSpot: Offset(0, 0),
  designHeight: 14,
  haloFraction: 0.10,
);

const _GlyphSpec _kClosedHand = _GlyphSpec(
  vertices: [
    // More compact silhouette — fingers curled, no fingertip bumps.
    Offset(-4, -4),
    Offset(-2, -5),
    Offset(2, -5),
    Offset(4, -4),
    Offset(4.5, 0),
    Offset(4, 5),
    Offset(2.5, 6.5),
    Offset(-2.5, 6.5),
    Offset(-4, 5),
    Offset(-4.5, 0),
  ],
  hotSpot: Offset(0, 0),
  designHeight: 12,
  haloFraction: 0.10,
);

// =====================================================================
// Not allowed (forbidden symbol)
// =====================================================================
//
// Circle with a diagonal slash. Implemented as two primitives instead
// of a polygon since the circle is more naturally expressed via
// drawCircle.

void _paintNotAllowed(Canvas canvas, Offset position, double diameter) {
  final radius = diameter * 0.5;
  // Stroke widths chosen so the slash and the ring read as similar
  // weights (matches macOS notallowed.svg roughly).
  final ringWidth = diameter * 0.18;
  final slashWidth = diameter * 0.14;
  final haloPadding = diameter * 0.06;

  // Halo: slightly fatter ring + slash.
  final haloPaint = Paint()
    ..style = PaintingStyle.stroke
    ..color = Colors.white
    ..strokeCap = StrokeCap.round;
  haloPaint.strokeWidth = ringWidth + 2 * haloPadding;
  canvas.drawCircle(position, radius, haloPaint);
  haloPaint.strokeWidth = slashWidth + 2 * haloPadding;
  // Diagonal slash from upper-right to lower-left, inset from the ring
  // by ~12% so it sits inside cleanly. The macOS forbidden cursor
  // uses NW-SE; we do the same.
  final slashOffset = diameter * 0.34;
  canvas.drawLine(
    position + Offset(-slashOffset, -slashOffset),
    position + Offset(slashOffset, slashOffset),
    haloPaint,
  );

  // Body (black ring + slash).
  final bodyPaint = Paint()
    ..style = PaintingStyle.stroke
    ..color = Colors.black
    ..strokeCap = StrokeCap.round;
  bodyPaint.strokeWidth = ringWidth;
  canvas.drawCircle(position, radius, bodyPaint);
  bodyPaint.strokeWidth = slashWidth;
  canvas.drawLine(
    position + Offset(-slashOffset, -slashOffset),
    position + Offset(slashOffset, slashOffset),
    bodyPaint,
  );
}
