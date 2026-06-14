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
}
