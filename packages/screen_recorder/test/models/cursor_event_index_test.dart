import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

CursorRecording _record(
    List<({int micros, double x, double y, bool clicked})> samples) {
  final r = CursorRecording();
  for (final s in samples) {
    r.addPosition(CursorPosition(
      x: s.x, y: s.y, timestampMicros: s.micros, isClicked: s.clicked,
    ));
  }
  return r;
}

void main() {
  group('CursorRecording.eventIndex (cached O(log N) lookups)', () {
    test('lastClickAtOrBefore returns null for an empty recording', () {
      final r = CursorRecording();
      expect(r.eventIndex.lastClickAtOrBefore(0), isNull);
      expect(r.eventIndex.lastClickAtOrBefore(1000000), isNull);
    });

    test('lastClickAtOrBefore returns null when t is before any click', () {
      final r = _record([
        (micros: 100000, x: 10, y: 10, clicked: false),
        (micros: 200000, x: 20, y: 20, clicked: true),
        (micros: 300000, x: 30, y: 30, clicked: true),
      ]);
      expect(r.eventIndex.lastClickAtOrBefore(50000), isNull);
      // 150000 µs is between the no-click sample and the first true sample
      // → no click event has happened yet.
      expect(r.eventIndex.lastClickAtOrBefore(150000), isNull);
    });

    test('lastClickAtOrBefore returns the click event at the moment of click',
        () {
      // false→true transition at t=200000 with cursor at (20, 20).
      final r = _record([
        (micros: 100000, x: 10, y: 10, clicked: false),
        (micros: 200000, x: 20, y: 20, clicked: true),
        (micros: 300000, x: 30, y: 30, clicked: true),
      ]);
      final ev = r.eventIndex.lastClickAtOrBefore(200000);
      expect(ev, isNotNull);
      expect(ev!.timestampMicros, 200000);
      expect(ev.screenPos, const Offset(20, 20));
    });

    test(
      'lastClickAtOrBefore returns the LATEST click ≤ t when multiple '
      'clicks have happened',
      () {
        // Three click events: t=200k, t=500k, t=800k. Verify lookup at
        // various points returns the right one.
        final r = _record([
          (micros: 100000, x: 0, y: 0, clicked: false),
          (micros: 200000, x: 10, y: 10, clicked: true),
          (micros: 300000, x: 10, y: 10, clicked: false),
          (micros: 500000, x: 50, y: 50, clicked: true),
          (micros: 600000, x: 50, y: 50, clicked: false),
          (micros: 800000, x: 80, y: 80, clicked: true),
          (micros: 900000, x: 80, y: 80, clicked: false),
        ]);
        final idx = r.eventIndex;
        expect(idx.lastClickAtOrBefore(150000), isNull);
        expect(idx.lastClickAtOrBefore(250000)!.timestampMicros, 200000);
        expect(idx.lastClickAtOrBefore(499999)!.timestampMicros, 200000);
        expect(idx.lastClickAtOrBefore(500000)!.timestampMicros, 500000);
        expect(idx.lastClickAtOrBefore(750000)!.timestampMicros, 500000);
        expect(idx.lastClickAtOrBefore(800000)!.timestampMicros, 800000);
        expect(idx.lastClickAtOrBefore(10000000)!.timestampMicros, 800000);
      },
    );

    test('lastReleaseAtOrBefore returns the timestamp of the most recent '
        'button-up event', () {
      final r = _record([
        (micros: 100000, x: 0, y: 0, clicked: false),
        (micros: 200000, x: 0, y: 0, clicked: true),
        (micros: 300000, x: 0, y: 0, clicked: false), // release at 300k
        (micros: 500000, x: 0, y: 0, clicked: true),
        (micros: 600000, x: 0, y: 0, clicked: false), // release at 600k
      ]);
      final idx = r.eventIndex;
      expect(idx.lastReleaseAtOrBefore(250000), isNull,
          reason: 'No release has happened yet during the first press');
      expect(idx.lastReleaseAtOrBefore(350000), 300000);
      expect(idx.lastReleaseAtOrBefore(500000), 300000);
      expect(idx.lastReleaseAtOrBefore(700000), 600000);
    });

    test('cache rebuilds after a mutation', () {
      // Adding a click after taking the index must surface in subsequent
      // lookups. Without invalidation, the new click would be invisible
      // and click ripples wouldn't fire during live recording.
      final r = _record([
        (micros: 100000, x: 0, y: 0, clicked: false),
      ]);
      expect(r.eventIndex.lastClickAtOrBefore(1000000), isNull);

      r.addPosition(const CursorPosition(
        x: 50, y: 50, timestampMicros: 200000, isClicked: true,
      ));
      final ev = r.eventIndex.lastClickAtOrBefore(1000000);
      expect(ev, isNotNull);
      expect(ev!.timestampMicros, 200000);
    });

    test('binary-search lookup matches the O(N) walk for a long recording',
        () {
      // Hammer test: 50 sample-pairs producing 50 click events at
      // 100ms intervals. Spot-check that the indexed lookup matches
      // mostRecentClickEvent's contract at multiple query points.
      final r = CursorRecording();
      for (var i = 0; i < 50; i++) {
        final baseMs = i * 100;
        r.addPosition(CursorPosition(
          x: i.toDouble(),
          y: 0,
          timestampMicros: baseMs * 1000,
          isClicked: false,
        ));
        r.addPosition(CursorPosition(
          x: i.toDouble(),
          y: 0,
          timestampMicros: (baseMs + 1) * 1000,
          isClicked: true,
        ));
        r.addPosition(CursorPosition(
          x: i.toDouble(),
          y: 0,
          timestampMicros: (baseMs + 2) * 1000,
          isClicked: false,
        ));
      }

      final idx = r.eventIndex;
      for (var q = 0; q < 50; q++) {
        final tQuery = q * 100 * 1000 + 5 * 1000; // mid-window
        final expectedClickTs = q * 100 * 1000 + 1 * 1000;
        expect(
          idx.lastClickAtOrBefore(tQuery)!.timestampMicros,
          expectedClickTs,
          reason: 'q=$q (lookup at $tQuery µs)',
        );
      }
    });
  });
}
