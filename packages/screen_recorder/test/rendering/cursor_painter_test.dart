import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
import 'package:screen_recorder/rendering/cursor_painter.dart';

/// A Canvas that records every drawCircle / drawPath call so tests can
/// assert WHERE on the canvas the renderer placed each element. Other
/// methods no-op so the function under test runs to completion.
class _RecordingCanvas implements ui.Canvas {
  final List<({Offset center, double radius, PaintingStyle style})> circles =
      [];
  final List<String> events = [];

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    circles.add((center: c, radius: radius, style: paint.style));
    events.add('drawCircle');
  }

  @override
  void drawPath(Path path, Paint paint) {
    events.add('drawPath');
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    events.add('drawLine');
  }

  @override
  noSuchMethod(Invocation invocation) {
    if (invocation.isMethod) {
      events.add(invocation.memberName.toString().replaceAll(
          RegExp(r'Symbol\("|"\)'), ''));
    }
    return null;
  }
}

void main() {
  group('paintCursorComposed', () {
    test('anchors the ripple at clickPosition, not cursorPosition', () {
      // Bug #1 in the architecture review: CursorRenderer was using
      // paintCursorWithEffects which painted the ripple at the current
      // cursor position, not at the position where the click happened.
      // Manifested in exported MP4s but not in preview because the
      // preview painters call paintCursorRipple separately with the
      // recovered click position.
      //
      // The unified entry point must take both positions and route
      // them correctly. Without this assert, the bug recurs the next
      // time someone reaches for a "convenient" all-in-one wrapper.
      final canvas = _RecordingCanvas();
      paintCursorComposed(
        canvas,
        const CursorPaintRequest(
          cursorPosition: Offset(500, 300),
          clickPosition: Offset(100, 100),
          microsSinceClick: 100000, // 100 ms — ripple is active
          baseDiameter: 32,
          clickEffect: CursorClickEffect.ripple,
        ),
      );

      // The ripple circle is drawn with PaintingStyle.stroke (from
      // paintCursorRipple). The glyph also draws circles for the dot
      // style but with fill; in the default modernDark style the glyph
      // uses paths, not circles. So the stroked-circle list isolates
      // the ripple.
      final rippleCircles = canvas.circles
          .where((c) => c.style == PaintingStyle.stroke)
          .toList();
      expect(rippleCircles, hasLength(1),
          reason: 'Exactly one ripple ring should be drawn for an active '
              'click with effect=ripple');
      expect(rippleCircles.first.center, const Offset(100, 100),
          reason:
              'Ripple must anchor at clickPosition, not cursorPosition');
    });

    test('skips the ripple entirely when clickPosition is null', () {
      // No click event yet at this playhead → no ripple, even if the
      // effect is set to ripple.
      final canvas = _RecordingCanvas();
      paintCursorComposed(
        canvas,
        const CursorPaintRequest(
          cursorPosition: Offset(50, 50),
          clickPosition: null,
          microsSinceClick: null,
          baseDiameter: 32,
          clickEffect: CursorClickEffect.ripple,
        ),
      );

      final rippleCircles = canvas.circles
          .where((c) => c.style == PaintingStyle.stroke)
          .toList();
      expect(rippleCircles, isEmpty);
    });

    test('skips the ripple when clickEffect is none', () {
      // Ripple effect off → no ring even if the click event itself is
      // active. The press-pulse on the glyph still plays (handled by
      // microsSinceClick passing through to paintCursorGlyphWithPulse).
      final canvas = _RecordingCanvas();
      paintCursorComposed(
        canvas,
        const CursorPaintRequest(
          cursorPosition: Offset(50, 50),
          clickPosition: Offset(50, 50),
          microsSinceClick: 80000,
          baseDiameter: 32,
          clickEffect: CursorClickEffect.none,
        ),
      );

      final rippleCircles = canvas.circles
          .where((c) => c.style == PaintingStyle.stroke)
          .toList();
      expect(rippleCircles, isEmpty);
    });

    test('forwards press-pulse timing to the glyph (cursor body shrinks '
        'shortly after click)', () {
      // The glyph's drawn radius isn't directly observable through the
      // recording canvas for non-circle styles, but the dot style draws
      // a single filled circle whose radius is baseDiameter * pulse / 2.
      // Mid-press the pulse multiplier is below 1.0, so the dot's
      // radius shrinks. Tests that microsSinceClick is wired through.
      final atRest = _RecordingCanvas();
      paintCursorComposed(
        atRest,
        const CursorPaintRequest(
          cursorPosition: Offset(80, 80),
          clickPosition: null,
          microsSinceClick: null,
          baseDiameter: 40,
          style: CursorStyle.dot,
        ),
      );

      final midPress = _RecordingCanvas();
      paintCursorComposed(
        midPress,
        const CursorPaintRequest(
          cursorPosition: Offset(80, 80),
          clickPosition: Offset(80, 80),
          microsSinceClick: 40000, // 40 ms into the press
          baseDiameter: 40,
          style: CursorStyle.dot,
        ),
      );

      // Dot glyphs draw filled circles. Pick the largest filled circle
      // from each canvas — that's the dot body.
      double largestFilled(List<({Offset center, double radius, PaintingStyle style})> circles) {
        return circles
            .where((c) => c.style == PaintingStyle.fill)
            .map((c) => c.radius)
            .fold(0.0, (a, b) => b > a ? b : a);
      }

      final restRadius = largestFilled(atRest.circles);
      final pressRadius = largestFilled(midPress.circles);
      expect(restRadius, greaterThan(0),
          reason: 'Dot glyph must draw a filled circle');
      expect(pressRadius, lessThan(restRadius),
          reason: 'Mid-press, the press-pulse multiplier <1.0 must shrink '
              'the glyph radius below its at-rest size');
    });
  });
}
