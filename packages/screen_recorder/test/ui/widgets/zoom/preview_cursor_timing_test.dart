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
      // Raw advanced 16ms but latency jumped from zero beyond the 50ms cap:
      // adjusted=966 < previous=1000, so the emitted playhead must hold.
      expect(
        steadyPreviewPlayhead(
          rawPlayhead: const Duration(milliseconds: 1016),
          displayLatency: const Duration(milliseconds: 80),
          prevRawPlayhead: const Duration(milliseconds: 1000),
          prevEmitted: const Duration(milliseconds: 1000),
        ),
        const Duration(milliseconds: 1000),
      );
    });

    test('resumes advancing once adjusted passes the held value', () {
      expect(
        steadyPreviewPlayhead(
          rawPlayhead: const Duration(milliseconds: 1070),
          displayLatency: const Duration(milliseconds: 50),
          prevRawPlayhead: const Duration(milliseconds: 1016),
          prevEmitted: const Duration(milliseconds: 1000),
        ),
        const Duration(milliseconds: 1020),
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
        const Duration(milliseconds: 7650),
        reason: 'preview must not stay frozen ~1.7s behind the play clock',
      );
    });

    test('a long VFR frame cannot masquerade as decode latency', () {
      // Sparse screen recordings may keep one encoded frame alive for over a
      // second. The native probe sees clock-frameStart and reports that whole
      // age, but cursor/camera time must remain within the bounded correction.
      expect(
        steadyPreviewPlayhead(
          rawPlayhead: const Duration(milliseconds: 29800),
          displayLatency: const Duration(milliseconds: 1150),
          prevRawPlayhead: const Duration(milliseconds: 29784),
          prevEmitted: const Duration(milliseconds: 29734),
        ),
        const Duration(milliseconds: 29750),
      );
    });

    test('first frame after play or seek also bounds VFR latency', () {
      // No history used to bypass the monotonic floor and subtract the full
      // latency once, producing an immediate backward jump on resume.
      expect(
        steadyPreviewPlayhead(
          rawPlayhead: const Duration(milliseconds: 28750),
          displayLatency: const Duration(milliseconds: 1200),
          prevRawPlayhead: null,
          prevEmitted: null,
        ),
        const Duration(milliseconds: 28700),
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
