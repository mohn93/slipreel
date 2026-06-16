import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/audio/waveform_extractor.dart';

void main() {
  group('reducePcmToPeaks', () {
    test('empty input -> empty peaks', () {
      expect(reducePcmToPeaks(Int16List(0), samplesPerBucket: 80), isEmpty);
    });

    test('buckets by samplesPerBucket and normalizes to global max', () {
      // 160 samples => 2 buckets at samplesPerBucket=80.
      // Bucket 0 peak = 4000, bucket 1 peak = 8000 => normalized 0.5, 1.0.
      final s = Int16List(160);
      for (var i = 0; i < 80; i++) {
        s[i] = (i.isEven ? 4000 : -4000);
      }
      for (var i = 80; i < 160; i++) {
        s[i] = (i.isEven ? 8000 : -8000);
      }
      final peaks = reducePcmToPeaks(s, samplesPerBucket: 80);
      expect(peaks.length, 2);
      expect(peaks[0], closeTo(0.5, 1e-6));
      expect(peaks[1], closeTo(1.0, 1e-6));
    });

    test('all-silence stays all-zero (no divide-by-zero)', () {
      final peaks = reducePcmToPeaks(Int16List(240), samplesPerBucket: 80);
      expect(peaks.length, 3);
      expect(peaks.every((p) => p == 0.0), isTrue);
    });
  });

  group('buildWaveformPcmArgs', () {
    test('single stream maps the first audio stream directly', () {
      final args = buildWaveformPcmArgs('/x/rec.mp4', 1);
      expect(args, containsAllInOrder(['-map', '0:a:0']));
      expect(args, containsAllInOrder(['-ar', '8000']));
      expect(args, containsAllInOrder(['-f', 's16le', '-']));
      expect(args.contains('-filter_complex'), isFalse);
    });

    test('two streams amix down to one labelled output', () {
      final args = buildWaveformPcmArgs('/x/rec.mp4', 2);
      expect(args, containsAllInOrder(['-filter_complex',
          '[0:a:0][0:a:1]amix=inputs=2:duration=longest[aout]']));
      expect(args, containsAllInOrder(['-map', '[aout]']));
      expect(args, containsAllInOrder(['-ac', '1', '-ar', '8000']));
    });
  });
}
