import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/audio/waveform_peaks.dart';
import 'package:screen_recorder/state/waveform_provider.dart';

void main() {
  test('sidecar save -> load round-trips', () async {
    final dir = await Directory.systemTemp.createTemp('wf_sidecar');
    addTearDown(() => dir.delete(recursive: true));
    final videoPath = '${dir.path}/rec.mp4';

    final peaks = WaveformPeaks(
      bucketsPerSecond: 100,
      peaks: const [0.0, 0.5, 1.0],
      sourceDuration: const Duration(milliseconds: 30),
    );

    await saveWaveformSidecar(videoPath, peaks);
    expect(File('$videoPath.waveform.json').existsSync(), isTrue);

    final loaded = await loadWaveformSidecar(videoPath);
    expect(loaded, isNotNull);
    expect(loaded!.peaks.length, 3);
    expect(loaded.bucketsPerSecond, 100);
    expect(loaded.peaks[1], closeTo(0.5, 1 / 255)); // 8-bit quant tolerance
  });

  test('load returns null when no sidecar exists', () async {
    final loaded = await loadWaveformSidecar('/no/such/rec.mp4');
    expect(loaded, isNull);
  });

  test('load returns null on a version mismatch', () async {
    final dir = await Directory.systemTemp.createTemp('wf_sidecar_ver');
    addTearDown(() => dir.delete(recursive: true));
    final videoPath = '${dir.path}/rec.mp4';
    await File('$videoPath.waveform.json')
        .writeAsString('{"version":999,"bucketsPerSecond":100,'
            '"sourceDurationMicros":1000,"peaks":[1,2,3]}');

    final loaded = await loadWaveformSidecar(videoPath);
    expect(loaded, isNull);
  });
}
