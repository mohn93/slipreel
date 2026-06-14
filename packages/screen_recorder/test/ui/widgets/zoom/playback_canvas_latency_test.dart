import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/zoom/preview_cursor_timing.dart';

// PlaybackCanvas needs a live VideoPlayerController/texture which can't run in a
// unit test, so we assert the timing contract the widget relies on directly:
// while playing, the cursor lookup time is the playhead minus the current
// display latency; while paused, latency is not applied.
void main() {
  test('playing branch subtracts the listenable latency', () {
    final latency = ValueNotifier<Duration>(const Duration(milliseconds: 70));
    const rawPos = Duration(milliseconds: 1000);
    final pos = previewPlayheadWithLatency(
      playhead: rawPos,
      displayLatency: latency.value,
    );
    expect(pos, const Duration(milliseconds: 930));
  });

  test('null latency listenable falls back to no shift', () {
    const rawPos = Duration(milliseconds: 1000);
    final ValueListenable<Duration>? latency = null;
    final pos = previewPlayheadWithLatency(
      playhead: rawPos,
      displayLatency: latency?.value ?? Duration.zero,
    );
    expect(pos, rawPos);
  });
}
