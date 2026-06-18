import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/audio/waveform_peaks.dart';

void main() {
  group('WaveformPeaks.slice', () {
    final peaks = WaveformPeaks(
      bucketsPerSecond: 100,
      peaks: List<double>.generate(1000, (i) => (i % 100) / 100.0), // 10s
      sourceDuration: const Duration(seconds: 10),
    );

    test('returns the bucket sub-range for a source window', () {
      // 2.00s .. 3.00s at 100 buckets/s => indices 200..300
      final sub = peaks.slice(
        const Duration(seconds: 2),
        const Duration(seconds: 3),
      );
      expect(sub.length, 100);
      expect(sub.first, closeTo(0.0, 1e-9)); // bucket 200 => (200%100)/100 = 0
    });

    test('clamps to array bounds', () {
      final sub = peaks.slice(
        const Duration(seconds: 9),
        const Duration(seconds: 20),
      );
      expect(sub.length, 100); // 900..1000 clamped
    });

    test('returns empty for a degenerate window', () {
      final sub = peaks.slice(
        const Duration(seconds: 5),
        const Duration(seconds: 5),
      );
      expect(sub, isEmpty);
    });
  });

  group('WaveformPeaks json + equality', () {
    final peaks = WaveformPeaks(
      bucketsPerSecond: 100,
      peaks: const [0.0, 0.5, 1.0, 0.25],
      sourceDuration: const Duration(milliseconds: 40),
    );

    test('round-trips through json (8-bit quantized)', () {
      final restored = WaveformPeaks.fromJson(peaks.toJson());
      expect(restored.bucketsPerSecond, 100);
      expect(restored.sourceDuration, const Duration(milliseconds: 40));
      expect(restored.peaks.length, 4);
      // 8-bit quantization tolerance.
      for (var i = 0; i < 4; i++) {
        expect(restored.peaks[i], closeTo(peaks.peaks[i], 1 / 255));
      }
    });

    test('fromJson rejects a mismatched version', () {
      final json = peaks.toJson()..['version'] = 999;
      expect(() => WaveformPeaks.fromJson(json), throwsFormatException);
    });

    test('== and hashCode are value-based', () {
      final a = WaveformPeaks(
        bucketsPerSecond: 100,
        peaks: const [0.1, 0.2],
        sourceDuration: const Duration(seconds: 1),
      );
      final b = WaveformPeaks(
        bucketsPerSecond: 100,
        peaks: const [0.1, 0.2],
        sourceDuration: const Duration(seconds: 1),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
