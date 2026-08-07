import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/cursor_interaction.dart';
import 'package:slipreel_engine/editor/zoom_shape.dart';

void main() {
  test('every interaction kind has a shape', () {
    for (final kind in InteractionKind.values) {
      expect(kZoomShapes[kind], isNotNull, reason: 'missing shape for $kind');
    }
  });

  test('click shape matches the historic auto-zoom defaults', () {
    final shape = kZoomShapes[InteractionKind.click]!;
    expect(shape.zoomLevel, 1.5);
    expect(shape.leadIn, const Duration(milliseconds: 500));
    expect(shape.hold, const Duration(milliseconds: 1800));
    expect(shape.leadOut, const Duration(milliseconds: 500));
    // Click zooms follow as of 2026-08-06: the camera tracks the cursor
    // after the click instead of sitting on a clamped box centre. Bounded
    // follow holds until the cursor leaves 80% of the viewport, so a click
    // where the pointer stays put still produces no motion.
    expect(shape.followCursor, isTrue);
    expect(shape.holdTracksGesture, isFalse);
    expect(shape.fitToSweptBounds, isFalse);
  });

  test('textEntry zooms tighter and holds longer than a click', () {
    final click = kZoomShapes[InteractionKind.click]!;
    final text = kZoomShapes[InteractionKind.textEntry]!;
    expect(text.zoomLevel, greaterThan(click.zoomLevel));
    expect(text.hold, greaterThan(click.hold));
    expect(text.followCursor, isFalse);
  });

  test('drag zooms looser than a click and follows', () {
    final click = kZoomShapes[InteractionKind.click]!;
    final drag = kZoomShapes[InteractionKind.drag]!;
    expect(drag.zoomLevel, lessThan(click.zoomLevel));
    expect(drag.followCursor, isTrue);
    expect(drag.holdTracksGesture, isTrue);
  });

  test('textSelection frames the swept bounds without following', () {
    final sel = kZoomShapes[InteractionKind.textSelection]!;
    // Anchored on purpose: the fitted centre is only honoured when the
    // camera is not chasing the cursor.
    expect(sel.followCursor, isFalse);
    expect(sel.fitToSweptBounds, isTrue);
    expect(sel.holdTracksGesture, isTrue);
  });

  test('absolute hold ignores gesture length', () {
    final shape = kZoomShapes[InteractionKind.click]!;
    expect(
      shape.effectiveHold(const Duration(seconds: 4)),
      const Duration(milliseconds: 1800),
    );
  });

  test('gesture-tracking hold adds the gesture duration', () {
    final shape = kZoomShapes[InteractionKind.drag]!;
    expect(
      shape.effectiveHold(const Duration(milliseconds: 1200)),
      const Duration(milliseconds: 2000),
    );
  });

  test('gesture-tracking hold is capped at maxHold', () {
    final shape = kZoomShapes[InteractionKind.drag]!;
    expect(
      shape.effectiveHold(const Duration(seconds: 30)),
      ZoomShape.maxHold,
    );
  });
}
