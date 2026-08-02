import 'dart:math' as math;
import 'dart:ui';

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../models/cursor_recording.dart';
import 'cursor_interaction.dart';

/// Pure `CursorRecording` → `List<CursorInteraction>` classifier.
///
/// Knows nothing about zoom, regions, or the editor. [videoSize] is a
/// scale reference only, so displacement thresholds are
/// resolution-independent.
class InteractionClassifier {
  const InteractionClassifier({
    this.dragDisplacementRatio = 0.02,
    this.dragMinDwell = const Duration(milliseconds: 200),
    this.horizontalAxisRatio = 1.8,
    this.stateLookback = const Duration(milliseconds: 50),
  });

  /// Press→release displacement, as a fraction of the video diagonal,
  /// above which a gesture counts as travel rather than a click.
  /// Measured against the diagonal rather than the width so the
  /// threshold behaves the same on wide and tall displays.
  final double dragDisplacementRatio;

  /// Minimum press duration for a displaced gesture to count as a drag.
  /// Below this, fast displaced presses are click-with-jitter.
  final Duration dragMinDwell;

  /// How much more horizontal than vertical a drag must be to read as a
  /// text selection rather than a generic drag.
  final double horizontalAxisRatio;

  /// Backward window before the press over which the pointer state is
  /// sampled. Reading state at exactly the press sample is vulnerable to
  /// the OS swapping the cursor *in response* to the click; sampling
  /// just before captures what the pointer was over when the user
  /// decided to click, which is the signal we want.
  final Duration stateLookback;

  List<CursorInteraction> classify(CursorRecording cursor, Size videoSize) {
    final samples = cursor.positions;
    if (samples.length < 2) return const [];

    final diagonal = math.sqrt(
      videoSize.width * videoSize.width + videoSize.height * videoSize.height,
    );

    final out = <CursorInteraction>[];
    var pressIndex = -1;
    var prevClicked = samples.first.isClicked;

    for (var i = 1; i < samples.length; i++) {
      final clicked = samples[i].isClicked;
      if (clicked && !prevClicked) {
        pressIndex = i;
      } else if (!clicked && prevClicked && pressIndex >= 0) {
        out.add(_build(samples, pressIndex, i - 1, diagonal));
        pressIndex = -1;
      }
      prevClicked = clicked;
    }

    // A press still held at end-of-recording releases at the last sample.
    if (pressIndex >= 0) {
      out.add(_build(samples, pressIndex, samples.length - 1, diagonal));
    }

    return out;
  }

  CursorInteraction _build(
    List<CursorPosition> samples,
    int pressIndex,
    int releaseIndex,
    double diagonal,
  ) {
    final press = samples[pressIndex];
    final release = samples[releaseIndex];

    var minX = press.x;
    var maxX = press.x;
    var minY = press.y;
    var maxY = press.y;
    for (var i = pressIndex; i <= releaseIndex; i++) {
      final s = samples[i];
      if (s.x < minX) minX = s.x;
      if (s.x > maxX) maxX = s.x;
      if (s.y < minY) minY = s.y;
      if (s.y > maxY) maxY = s.y;
    }

    final state = _stateBefore(samples, pressIndex);
    final start = Duration(microseconds: press.timestampMicros);
    final end = Duration(microseconds: release.timestampMicros);

    final dx = (release.x - press.x).abs();
    final dy = (release.y - press.y).abs();
    final displacement = math.sqrt(dx * dx + dy * dy);

    final InteractionKind kind;
    if (displacement > dragDisplacementRatio * diagonal &&
        (end - start) >= dragMinDwell) {
      kind = (state == CursorState.iBeam && dx > horizontalAxisRatio * dy)
          ? InteractionKind.textSelection
          : InteractionKind.drag;
    } else {
      kind = state == CursorState.iBeam
          ? InteractionKind.textEntry
          : InteractionKind.click;
    }

    return CursorInteraction(
      kind: kind,
      start: start,
      end: end,
      anchor: Offset(press.x, press.y),
      sweptBounds: Rect.fromLTRB(minX, minY, maxX, maxY),
      state: state,
    );
  }

  /// Modal pointer state over `[press - stateLookback, press]`. Walking
  /// backwards means that on a count tie the state nearest the press
  /// wins, because Dart maps iterate in insertion order and we insert
  /// nearest-first.
  CursorState _stateBefore(List<CursorPosition> samples, int pressIndex) {
    final windowStart =
        samples[pressIndex].timestampMicros - stateLookback.inMicroseconds;
    final counts = <CursorState, int>{};
    for (var i = pressIndex; i >= 0; i--) {
      final s = samples[i];
      if (s.timestampMicros < windowStart) break;
      counts[s.state] = (counts[s.state] ?? 0) + 1;
    }
    if (counts.isEmpty) return samples[pressIndex].state;

    var best = counts.keys.first;
    var bestCount = counts[best]!;
    counts.forEach((state, count) {
      if (count > bestCount) {
        best = state;
        bestCount = count;
      }
    });
    return best;
  }
}
