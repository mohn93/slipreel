// m9: the export progress denominator must track the EDITED output length, not
// the full source duration, or the bar freezes short of 100% on trimmed exports.
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';

void main() {
  test('prefers the edited output duration over the source duration', () {
    // 30s source, but only 10s survives the trim. At 60fps the encoder emits
    // 600 frames — the denominator must be 600, not 1800.
    final frames = expectedOutputFrames(
      outputDurationSec: 10,
      pipelineFps: 60,
      sourceDurationSec: 30,
      sourceNbFrames: 1800,
      sourceFps: 60,
    );
    expect(frames, 600);
  });

  test('falls back to source duration when output length is unknown', () {
    expect(
      expectedOutputFrames(
        outputDurationSec: 0,
        pipelineFps: 30,
        sourceDurationSec: 4,
      ),
      120,
    );
  });

  test('falls back to nb_frames scaled by the rate ratio', () {
    // 300 source frames at 30fps → 10s → 600 frames at 60fps.
    expect(
      expectedOutputFrames(
        outputDurationSec: 0,
        pipelineFps: 60,
        sourceNbFrames: 300,
        sourceFps: 30,
      ),
      600,
    );
  });

  test('returns null when nothing usable is available (indeterminate bar)', () {
    expect(
      expectedOutputFrames(outputDurationSec: 0, pipelineFps: 60),
      isNull,
    );
  });
}
