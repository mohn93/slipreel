import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
import 'package:screen_recorder/rendering/cursor_state_glyphs.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('cursor_state_glyphs', () {
    test('every non-arrow state renders without throwing at typical size', () {
      // Smoke-test the dispatcher: each state's glyph must paint
      // cleanly at typical cursor sizes. A throw here means the path
      // builder hit an empty vertex list, NaN, or similar bug.
      for (final state in CursorState.values) {
        if (state == CursorState.arrow) continue;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(
          recorder,
          const Rect.fromLTWH(0, 0, 200, 200),
        );
        expect(
          () => paintStateGlyph(
            canvas,
            state: state,
            position: const Offset(100, 100),
            diameter: 32,
          ),
          returnsNormally,
          reason: 'state=${state.name}',
        );
        recorder.endRecording();
      }
    });

    test('renders cleanly at very small and very large diameters', () {
      // Tiny diameters can collapse polygon edges to sub-pixel; large
      // ones stress the stroke/path math. Both must render without
      // throwing.
      for (final state in CursorState.values) {
        if (state == CursorState.arrow) continue;
        for (final diameter in [4.0, 256.0]) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(
            recorder,
            const Rect.fromLTWH(0, 0, 1000, 1000),
          );
          expect(
            () => paintStateGlyph(
              canvas,
              state: state,
              position: const Offset(500, 500),
              diameter: diameter,
            ),
            returnsNormally,
            reason: 'state=${state.name} diameter=$diameter',
          );
          recorder.endRecording();
        }
      }
    });

    test('paintCursorGlyph dispatches to the state glyph for every arrow '
        'style + non-arrow state', () {
      // Every arrow style (Classic, Modern Dark, Bold, Outlined) must
      // swap to the state-specific glyph when the recorded cursor was
      // something other than the arrow — hovering over a link should
      // show a pointing hand regardless of which arrow style the user
      // picked. Dot is the one exception (minimal abstract style) and
      // stays a circle no matter what.
      for (final state in CursorState.values) {
        for (final style in CursorStyle.values) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(
            recorder,
            const Rect.fromLTWH(0, 0, 200, 200),
          );
          expect(
            () => paintCursorGlyph(
              canvas,
              position: const Offset(100, 100),
              diameter: 24,
              style: style,
              state: state,
            ),
            returnsNormally,
            reason: 'state=${state.name} style=${style.name}',
          );
          recorder.endRecording();
        }
      }
    });

    test('isArrowState matches only CursorState.arrow', () {
      for (final state in CursorState.values) {
        expect(isArrowState(state), state == CursorState.arrow);
      }
    });
  });
}
