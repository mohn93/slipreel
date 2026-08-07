@TestOn('vm')
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';

/// Press timings and anchors taken from a real 1893x986 screen recording
/// (30 s, 11 detected presses). Under the pre-2026-08-06 rules this produced
/// 8 regions, two pairs of which abutted exactly — the seams that prompted
/// merging. See
/// docs/superpowers/specs/2026-08-06-auto-zoom-merge-and-follow-design.md
void main() {
  const videoSize = Size(1893, 986);

  // (pressMs, x, y). The press at 1699ms is at x=2861, off the captured
  // display — a second monitor. The bounds guard must drop it.
  const presses = <List<double>>[
    [375, 108, 66],
    [1699, 2861, 451],
    [3344, 145, 68],
    [3688, 153, 101],
    [5390, 126, 72],
    [5828, 130, 129],
    [10056, 1389, 340],
    [11780, 542, 132],
    [15098, 683, 284],
    [20115, 405, 126],
    [24586, 148, 919],
  ];

  CursorRecording build() {
    final rec = CursorRecording();
    // 60Hz idle track, with a ~95ms press plateau at each press time.
    for (var ms = 0; ms <= 29627; ms += 16) {
      var x = 900.0;
      var y = 500.0;
      var clicked = false;
      for (final p in presses) {
        if (ms >= p[0] - 200 && ms < p[0] + 200) {
          x = p[1];
          y = p[2];
        }
        if (ms >= p[0] && ms < p[0] + 95) clicked = true;
      }
      rec.addPosition(CursorPosition(
        x: x,
        y: y,
        timestampMicros: ms * 1000,
        isClicked: clicked,
      ));
    }
    return rec;
  }

  test('the real recording yields four merged following regions', () {
    final out = const AutoZoomDetector().detect(
      cursor: build(),
      videoSize: videoSize,
      videoDuration: const Duration(milliseconds: 29627),
    );

    expect(out, hasLength(4));

    // Every region follows: all eleven presses classify as plain clicks
    // (no cursor state in this track, and real presses are far shorter
    // than the 200ms drag dwell floor), and clicks follow.
    for (final r in out) {
      expect(r.followCursor, isTrue);
    }

    // Non-overlapping by construction.
    for (var i = 1; i < out.length; i++) {
      expect(
        out[i].startTime >= out[i - 1].startTime + out[i - 1].duration,
        isTrue,
        reason: 'region $i starts before region ${i - 1} ends',
      );
    }

    // The first region spans the five sidebar clicks that previously
    // produced three regions with two seams between them.
    expect(out.first.startTime, Duration.zero);
    expect(out.first.startTime + out.first.duration,
        greaterThan(const Duration(milliseconds: 7000)));
  });
}
