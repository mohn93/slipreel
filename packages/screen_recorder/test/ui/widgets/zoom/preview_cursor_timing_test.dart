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

    test('a runaway latency never freezes the preview far behind the clock', () {
      // Texture stalls during a GPU-heavy zoom: the latency estimate balloons
      // so `adjusted` falls ~1.7s behind while the raw clock keeps advancing.
      // The hold must NOT freeze the preview at prevEmitted (which stuck the
      // zoom at full magnification and never let it ramp out). The preview may
      // trail the real clock by at most the bounded max lag.
      final out = steadyPreviewPlayhead(
        rawPlayhead: const Duration(milliseconds: 7700),
        displayLatency: const Duration(milliseconds: 1704), // adjusted = 5996
        prevRawPlayhead: const Duration(milliseconds: 7680),
        prevEmitted: const Duration(milliseconds: 5996), // was held here
      );
      expect(
        out,
        greaterThan(const Duration(milliseconds: 7000)),
        reason: 'preview must not stay frozen ~1.7s behind the play clock',
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

  group('shouldUseDeterministicFocal', () {
    test('scrubbing → true (live spring is path-dependent there)', () {
      expect(
        shouldUseDeterministicFocal(
          isHoverScrubbing: true,
          isPlaying: false,
          hasOverride: false,
          followCursor: true,
        ),
        isTrue,
      );
    });

    test('paused (not playing) → true', () {
      expect(
        shouldUseDeterministicFocal(
          isHoverScrubbing: false,
          isPlaying: false,
          hasOverride: false,
          followCursor: true,
        ),
        isTrue,
      );
    });

    test('forward playback → true (stateful gate makes the live spring '
        'path-dependent; track keeps play == scrub == export)', () {
      expect(
        shouldUseDeterministicFocal(
          isHoverScrubbing: false,
          isPlaying: true,
          hasOverride: false,
          followCursor: true,
        ),
        isTrue,
      );
    });

    test('placement override active → false (override drives the focal)', () {
      expect(
        shouldUseDeterministicFocal(
          isHoverScrubbing: true,
          isPlaying: false,
          hasOverride: true,
          followCursor: true,
        ),
        isFalse,
      );
    });

    test('non-follow-cursor region → false (rect-center is already pure)', () {
      expect(
        shouldUseDeterministicFocal(
          isHoverScrubbing: true,
          isPlaying: false,
          hasOverride: false,
          followCursor: false,
        ),
        isFalse,
      );
    });
  });
}
