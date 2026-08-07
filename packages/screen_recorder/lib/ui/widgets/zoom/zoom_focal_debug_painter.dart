import 'package:flutter/material.dart';

import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/cursor_geometry.dart';

/// Dev HUD painter overlaid on the playback canvas. Renders the recorded
/// cursor trail, the raw cursor at the current playhead, the smoothed
/// zoom focal point, the bounded-mode deadzone box around the focal,
/// and a text readout of the controller's live state (follow mode,
/// deadzone ratio, `_inFlight`, spring velocity) so we can diagnose
/// "the camera is moving when it shouldn't" complaints by reading
/// ground truth straight off the screen.
class ZoomFocalDebugPainter extends CustomPainter {
  ZoomFocalDebugPainter({
    required this.cursorRecording,
    required this.position,
    required this.videoSize,
    required this.smoothedFocal,
    required this.activeZoom,
    required this.inFlight,
    required this.focalVelocity,
  });

  final CursorRecording cursorRecording;
  final Duration position;
  final Size videoSize;
  final Offset? smoothedFocal;
  /// The zoom the controller is currently treating as active, or null
  /// when the playhead is between regions. Useful for cross-checking
  /// against whatever the inspector panel is *showing*: if the
  /// inspector shows zoom #2 but this prints zoom #1, the user is
  /// editing the wrong region.
  final ZoomRegion? activeZoom;
  final bool inFlight;
  final Offset focalVelocity;

  @override
  void paint(Canvas canvas, Size size) {
    final raw = cursorAt(cursorRecording, position);
    final scaleX = size.width / videoSize.width;
    final scaleY = size.height / videoSize.height;

    // Trail: render every recorded cursor sample as a small dot, colored
    // by time (early=blue → late=red). Lets you see whether the saved
    // cursor path roughly matches the path you actually moved during
    // recording. If the trail looks completely different, the native
    // transform is producing wrong coordinates.
    final all = cursorRecording.positions;
    if (all.length > 1) {
      final n = all.length;
      final dotPaint = Paint();
      for (var i = 0; i < n; i++) {
        final p = all[i];
        final t = i / (n - 1);
        // HSL: 220° (blue) → 0° (red). Saturation 0.9, lightness 0.5.
        final hue = 220.0 * (1 - t);
        dotPaint.color = HSLColor.fromAHSL(0.6, hue, 0.9, 0.55).toColor();
        canvas.drawCircle(
            Offset(p.x * scaleX, p.y * scaleY), 2, dotPaint);
      }
    }

    if (raw != null) {
      final p = Offset(raw.x * scaleX, raw.y * scaleY);
      // Raw cursor: small filled cyan dot with black outline.
      canvas.drawCircle(p, 6,
          Paint()..color = const Color(0xCC00E5FF));
      canvas.drawCircle(
        p,
        6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.black87,
      );
    }

    if (smoothedFocal != null) {
      final f = Offset(smoothedFocal!.dx * scaleX, smoothedFocal!.dy * scaleY);
      // Deadzone box: magenta when idle, green
      // while the gate is bypassed (`_inFlight`). Drawn first so the
      // focal crosshair sits on top.
      final z = activeZoom;
      if (z != null &&
          z.followCursor &&
          z.followMode.usesDeadzone &&
          z.deadzoneRatio > 0 &&
          videoSize.width > 0 &&
          videoSize.height > 0) {
        final dzW = (videoSize.width / z.zoomLevel) * z.deadzoneRatio;
        final dzH = (videoSize.height / z.zoomLevel) * z.deadzoneRatio;
        final dzRect = Rect.fromCenter(
          center: f,
          width: dzW * scaleX,
          height: dzH * scaleY,
        );
        final dzPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = inFlight
              ? const Color(0xCC00E676) // green — gate bypassed
              : const Color(0xCCFF00C8); // magenta — gate active
        canvas.drawRect(dzRect, dzPaint);
      }
      // Smoothed focal: hollow yellow ring + crosshair.
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFFC107);
      canvas.drawCircle(f, 14, ringPaint);
      canvas.drawLine(Offset(f.dx - 18, f.dy), Offset(f.dx + 18, f.dy), ringPaint);
      canvas.drawLine(Offset(f.dx, f.dy - 18), Offset(f.dx, f.dy + 18), ringPaint);
    }

    // Text readout intentionally NOT drawn here — it now lives in a
    // sibling Flutter widget ([ZoomDebugReadoutPanel]) positioned
    // outside the video frame in the playback canvas's outer Stack,
    // so the diagnostic numbers don't sit on top of the playback
    // pixels we're trying to inspect.
  }

  @override
  bool shouldRepaint(ZoomFocalDebugPainter old) =>
      old.position != position ||
      old.cursorRecording != cursorRecording ||
      old.videoSize != videoSize ||
      old.smoothedFocal != smoothedFocal ||
      old.activeZoom != activeZoom ||
      old.inFlight != inFlight ||
      old.focalVelocity != focalVelocity;
}

/// Immutable snapshot of the zoom controller's state at one frame —
/// the payload the playback canvas pushes out via a `ValueNotifier`
/// so the debug readout can render at screen-fixed coordinates,
/// outside the zoom Transform that warps the canvas itself.
class ZoomDebugSnapshot {
  const ZoomDebugSnapshot({
    required this.cursor,
    required this.smoothedFocal,
    required this.activeZoom,
    required this.inFlight,
    required this.focalVelocity,
    required this.cursorVelocity,
    required this.videoSize,
    required this.cursorSampleCount,
    required this.position,
    this.cursorXRange,
    this.cursorYRange,
    this.lastSnapReason,
    this.lastSnapAt,
  });

  final Offset? cursor;
  final Offset? smoothedFocal;
  final ZoomRegion? activeZoom;
  final bool inFlight;
  final Offset focalVelocity;
  /// Cursor's intrinsic scene velocity in source-video px/s. This is
  /// the value the Smart-mode gate consults for "is the cursor at
  /// rest?" — if a snap is happening when the user reports the cursor
  /// as stopped, this tells us whether the gate sees a real velocity
  /// spike (e.g. from a click-injected sample landing 2 px off the
  /// trajectory) or whether the cursor is genuinely at rest and the
  /// snap is coming from somewhere downstream.
  final Offset cursorVelocity;
  final Size videoSize;
  final int cursorSampleCount;
  final Duration position;
  final (double, double)? cursorXRange;
  final (double, double)? cursorYRange;
  final String? lastSnapReason;
  final Duration? lastSnapAt;
}

/// Text readout sibling for [ZoomFocalDebugPainter]. Rendered as a
/// regular Flutter widget rather than baked into the painter so it
/// can be positioned OUTSIDE the video frame — sitting on top of the
/// playback pixels was hiding the very behaviour we needed to read.
class ZoomDebugReadoutPanel extends StatelessWidget {
  const ZoomDebugReadoutPanel({
    super.key,
    required this.cursor,
    required this.smoothedFocal,
    required this.activeZoom,
    required this.inFlight,
    required this.focalVelocity,
    required this.cursorVelocity,
    required this.videoSize,
    required this.cursorSampleCount,
    required this.position,
    this.cursorXRange,
    this.cursorYRange,
    this.lastSnapReason,
    this.lastSnapAt,
  });

  final Offset? cursor;
  final Offset? smoothedFocal;
  final ZoomRegion? activeZoom;
  final bool inFlight;
  final Offset focalVelocity;
  final Offset cursorVelocity;
  final Size videoSize;
  final int cursorSampleCount;
  final Duration position;
  final (double, double)? cursorXRange;
  final (double, double)? cursorYRange;
  final String? lastSnapReason;
  final Duration? lastSnapAt;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[];
    lines.add('samples: $cursorSampleCount');
    if (cursor == null) {
      lines.add('cursor: <none at this time>');
    } else {
      lines.add(
          'cursor: ${cursor!.dx.toStringAsFixed(0)}, ${cursor!.dy.toStringAsFixed(0)} px');
    }
    if (smoothedFocal != null) {
      lines.add(
          'focal:  ${smoothedFocal!.dx.toStringAsFixed(0)}, ${smoothedFocal!.dy.toStringAsFixed(0)} px');
    } else {
      lines.add('focal:  <no active zoom>');
    }
    final z = activeZoom;
    if (z != null) {
      lines.add('mode:   ${z.followMode.name}'
          '${z.followCursor ? "" : " (followCursor=off)"}');
      lines.add('dz:     ${(z.deadzoneRatio * 100).toStringAsFixed(0)}%'
          '   zoom: ${z.zoomLevel.toStringAsFixed(1)}×'
          '   t: ${z.followDuration.inMilliseconds}ms');
      lines.add('inFlight: ${inFlight ? "YES (gate bypassed)" : "no"}'
          '   |v|: ${focalVelocity.distance.toStringAsFixed(1)} px/s');
      lines.add('cursorV: ${cursorVelocity.distance.toStringAsFixed(1)} px/s'
          '   (gate release < 80)');
    }
    if (lastSnapReason != null && lastSnapAt != null) {
      final ageMs = position.inMicroseconds - lastSnapAt!.inMicroseconds;
      final ageStr = ageMs < 0
          ? '? ms (future)'
          : ageMs < 1000 * 1000
              ? '${(ageMs / 1000).toStringAsFixed(0)} ms ago'
              : '${(ageMs / 1e6).toStringAsFixed(1)} s ago';
      lines.add('snap:   $lastSnapReason  ($ageStr)');
    }
    if (cursorXRange != null && cursorYRange != null) {
      lines.add('x rng:  ${cursorXRange!.$1.toStringAsFixed(0)}'
          ' … ${cursorXRange!.$2.toStringAsFixed(0)}');
      lines.add('y rng:  ${cursorYRange!.$1.toStringAsFixed(0)}'
          ' … ${cursorYRange!.$2.toStringAsFixed(0)}');
    }
    lines.add(
        'video:  ${videoSize.width.toStringAsFixed(0)} × ${videoSize.height.toStringAsFixed(0)}');
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xCC000000),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: const Color(0x44FFFFFF), width: 0.5),
        ),
        child: Text(
          lines.join('\n'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            height: 1.35,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
