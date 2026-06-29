import 'dart:ui' show Rect, Size;

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/tilt3d.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

/// Returns a controller seeded with a 1000×1000 video project and padding=10.
EditorProjectController _makeController({double padding = 10}) {
  final initial = EditorProjectState.defaults().copyWith(
    windowFrame: WindowFrame.rounded().copyWith(
      padding: EdgeInsets.all(padding),
    ),
  );
  return EditorProjectController(initial: initial);
}

/// A minimal 3D zoom region (subtle tilt, 1000×1000 space).
ZoomRegion _zoom3D({ZoomTiltStyle style = ZoomTiltStyle.subtle}) => ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 1000, 1000),
      startTime: const Duration(milliseconds: 100),
      duration: const Duration(seconds: 1),
      zoomLevel: 2.0,
      tilt: Tilt3D(style: style),
    );

/// A minimal flat (2D) zoom region.
ZoomRegion get _zoom2D => ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 1000, 1000),
      startTime: const Duration(milliseconds: 100),
      duration: const Duration(seconds: 1),
      zoomLevel: 2.0,
    );

/// 6% of 1000 = 60.
const int _kExpectedFloor = 60;

/// A 1000×1000 video size for floor computation.
const Size _kVideoSize = Size(1000, 1000);

void main() {
  test('minPadding3DFor returns 6% of the video short side', () {
    expect(minPadding3DFor(const Size(1000, 1000)), equals(60));
    expect(minPadding3DFor(const Size(1920, 1080)), equals(65)); // 0.06*1080
    expect(minPadding3DFor(const Size(800, 600)), equals(36)); // 0.06*600
  });

  test('enabling a 3D zoom raises padding to the 6% floor', () {
    final c = _makeController(padding: 10);
    expect(c.current.windowFrame.padding.left, 10);

    c.addZoom(_zoom3D(), videoSize: _kVideoSize);

    expect(c.current.windowFrame.padding.left, _kExpectedFloor);
  });

  test('a 2D zoom does not change padding', () {
    final c = _makeController(padding: 10);

    c.addZoom(_zoom2D, videoSize: _kVideoSize);

    expect(c.current.windowFrame.padding.left, 10);
  });

  test('removing the last 3D zoom leaves the raised padding untouched', () {
    final c = _makeController(padding: 10);
    c.addZoom(_zoom3D(), videoSize: _kVideoSize);
    expect(c.current.windowFrame.padding.left, _kExpectedFloor);

    c.removeZoomAt(0);

    // Padding must NOT be lowered on remove.
    expect(c.current.windowFrame.padding.left, _kExpectedFloor);
  });

  test('floor enforcement raises only — padding above floor is preserved', () {
    final c = _makeController(padding: 150);

    c.addZoom(_zoom3D(), videoSize: _kVideoSize);

    // 150 > 60, so no raise.
    expect(c.current.windowFrame.padding.left, 150);
  });

  test('updateZoomAt to a 3D region raises padding', () {
    final c = _makeController(padding: 10);
    // Start with a 2D zoom so padding stays low.
    c.addZoom(_zoom2D, videoSize: _kVideoSize);
    expect(c.current.windowFrame.padding.left, 10);

    // Update it to a 3D zoom.
    c.updateZoomAt(0, _zoom3D(), videoSize: _kVideoSize);

    expect(c.current.windowFrame.padding.left, _kExpectedFloor);
  });
}
