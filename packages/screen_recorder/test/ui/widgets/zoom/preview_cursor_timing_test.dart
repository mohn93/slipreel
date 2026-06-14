import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/zoom/preview_cursor_timing.dart';

void main() {
  test('subtracts display latency from the playhead', () {
    final r = previewPlayheadWithLatency(
      playhead: const Duration(milliseconds: 1000),
      displayLatency: const Duration(milliseconds: 80),
    );
    expect(r, const Duration(milliseconds: 920));
  });

  test('zero latency is the identity', () {
    const p = Duration(milliseconds: 1234);
    expect(
      previewPlayheadWithLatency(playhead: p, displayLatency: Duration.zero),
      p,
    );
  });

  test('clamps to zero rather than going negative', () {
    final r = previewPlayheadWithLatency(
      playhead: const Duration(milliseconds: 30),
      displayLatency: const Duration(milliseconds: 80),
    );
    expect(r, Duration.zero);
  });

  group('steadyPreviewPlayhead', () {
    test('first frame (no history) = playhead - latency', () {
      expect(
        steadyPreviewPlayhead(
          rawPlayhead: const Duration(milliseconds: 1000),
          displayLatency: const Duration(milliseconds: 50),
          prevRawPlayhead: null,
          prevEmitted: null,
        ),
        const Duration(milliseconds: 950),
      );
    });

    test('forward raw + steady latency advances normally', () {
      expect(
        steadyPreviewPlayhead(
          rawPlayhead: const Duration(milliseconds: 1016),
          displayLatency: const Duration(milliseconds: 50),
          prevRawPlayhead: const Duration(milliseconds: 1000),
          prevEmitted: const Duration(milliseconds: 950),
        ),
        const Duration(milliseconds: 966),
      );
    });

    test('a latency spike that would reverse pos holds at prevEmitted', () {
      // raw advanced 16ms but latency jumped 50->80 → adjusted 936 < prev 950.
      expect(
        steadyPreviewPlayhead(
          rawPlayhead: const Duration(milliseconds: 1016),
          displayLatency: const Duration(milliseconds: 80),
          prevRawPlayhead: const Duration(milliseconds: 1000),
          prevEmitted: const Duration(milliseconds: 950),
        ),
        const Duration(milliseconds: 950),
      );
    });

    test('resumes advancing once adjusted passes the held value', () {
      expect(
        steadyPreviewPlayhead(
          rawPlayhead: const Duration(milliseconds: 1040),
          displayLatency: const Duration(milliseconds: 60),
          prevRawPlayhead: const Duration(milliseconds: 1016),
          prevEmitted: const Duration(milliseconds: 950),
        ),
        const Duration(milliseconds: 980),
      );
    });

    test('a real backward seek (raw moves back) is followed, not held', () {
      expect(
        steadyPreviewPlayhead(
          rawPlayhead: const Duration(milliseconds: 400),
          displayLatency: const Duration(milliseconds: 50),
          prevRawPlayhead: const Duration(milliseconds: 1016),
          prevEmitted: const Duration(milliseconds: 966),
        ),
        const Duration(milliseconds: 350),
      );
    });

    test('clamps to zero', () {
      expect(
        steadyPreviewPlayhead(
          rawPlayhead: const Duration(milliseconds: 30),
          displayLatency: const Duration(milliseconds: 80),
          prevRawPlayhead: null,
          prevEmitted: null,
        ),
        Duration.zero,
      );
    });
  });
}
