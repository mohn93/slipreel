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

    test('partial final bucket: ceil() path, peak over smaller sample set', () {
      // 200 samples => ceil(200/80) = 3 buckets (80, 80, 40 samples).
      // Bucket 0 peak = 2000, bucket 1 peak = 4000, bucket 2 (partial, 40
      // samples) peak = 8000 => global max => normalized 0.25, 0.5, 1.0.
      final s = Int16List(200);
      for (var i = 0; i < 80; i++) {
        s[i] = 2000;
      }
      for (var i = 80; i < 160; i++) {
        s[i] = 4000;
      }
      for (var i = 160; i < 200; i++) {
        s[i] = 8000;
      }
      final peaks = reducePcmToPeaks(s, samplesPerBucket: 80);
      expect(peaks.length, 3);
      expect(peaks[0], closeTo(0.25, 1e-6));
      expect(peaks[1], closeTo(0.5, 1e-6));
      expect(peaks[2], closeTo(1.0, 1e-6));
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
