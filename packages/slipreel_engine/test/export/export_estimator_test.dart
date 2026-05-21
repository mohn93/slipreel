import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_estimator.dart';
import 'package:slipreel_engine/models/export_settings.dart';

void main() {
  group('ExportEstimator', () {
    const estimator = ExportEstimator(lastRealtimeMultiplier: 0.7);

    group('estimateExportTime', () {
      test('1-second source at 0.7× → ~1.43s', () {
        final duration = estimator.estimateExportTime(1.0);
        expect(duration.inMilliseconds, closeTo(1428.0, 50));
      });

      test('0-second source → 0.5s floor', () {
        final duration = estimator.estimateExportTime(0.0);
        expect(duration.inMilliseconds, 500);
      });

      test('60-second source at 1.0× → 60s', () {
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final duration = estimator1x.estimateExportTime(60.0);
        expect(duration.inSeconds, 60);
      });

      test('custom multiplier affects result', () {
        const estimator05x = ExportEstimator(lastRealtimeMultiplier: 0.5);
        final duration05x = estimator05x.estimateExportTime(1.0);
        // 1.0 / 0.5 = 2.0s
        expect(duration05x.inMilliseconds, 2000);
      });

      test('60fps takes 2× the wall time of 30fps at the same realtime mult', () {
        const e = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final at30 = e.estimateExportTime(10.0, frameRate: 30);
        final at60 = e.estimateExportTime(10.0, frameRate: 60);
        expect(at30.inSeconds, 10);
        expect(at60.inSeconds, 20);
      });

      test('4K takes 4× the wall time of 1080p at the same fps', () {
        const e = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final at1080 =
            e.estimateExportTime(10.0, outputArea: 1920 * 1080);
        final at4k =
            e.estimateExportTime(10.0, outputArea: 3840 * 2160);
        expect(at1080.inSeconds, 10);
        expect(at4k.inSeconds, 40);
      });
    });

    group('estimateOutputBytes', () {
      test('1080p / Web tier (6000 kbps) × 30s MP4 → 23,040,000 bytes', () {
        final bytes = estimator.estimateOutputBytes(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.mp4,
        );
        expect(bytes, 23040000);
      });

      test('MP4 with audio bitrate adds the audio bytes to the total', () {
        final mp4NoAudio = estimator.estimateOutputBytes(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.mp4,
        );
        final mp4WithAudio = estimator.estimateOutputBytes(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.mp4,
          audioBitrateKbps: 128,
        );
        // 128 kbps × 30s / 8 × 1024 = 491,520 bytes added.
        expect(mp4WithAudio - mp4NoAudio, 491520);
      });

      test('GIF ignores audio bitrate (no audio in GIFs)', () {
        final gifNoAudio = estimator.estimateOutputBytes(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.gif,
        );
        final gifWithAudio = estimator.estimateOutputBytes(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.gif,
          audioBitrateKbps: 128,
        );
        expect(gifWithAudio, gifNoAudio);
      });

      test('same params but format=GIF applies 0.6 calibration', () {
        final bytesMP4 = estimator.estimateOutputBytes(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.mp4,
        );
        final bytesGIF = estimator.estimateOutputBytes(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.gif,
        );
        expect(bytesMP4, 23040000);
        expect(bytesGIF, 13824000); // 23,040,000 × 0.6 rounded.
      });

      test('0-second duration → 0 bytes', () {
        final bytes = estimator.estimateOutputBytes(
          durationSec: 0.0,
          bitrateKbps: 6000,
          format: ExportFormat.mp4,
        );
        expect(bytes, 0);
      });
    });

    group('formatLine', () {
      test('1-second clip with tiny output formats verbatim', () {
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final line = estimator1x.formatLine(
          durationSec: 1.0,
          bitrateKbps: 1000,
          format: ExportFormat.mp4,
        );
        // 1000 kbps × 1s / 8 × 1024 = 128000 bytes ≈ 125.0KB
        expect(line, 'Estimation — Export time 1 second — Output size 125.0KB');
      });

      test('plural seconds format', () {
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final line = estimator1x.formatLine(
          durationSec: 5.0,
          bitrateKbps: 256,
          format: ExportFormat.mp4,
        );
        expect(line, 'Estimation — Export time 5 seconds — Output size 160.0KB');
      });

      test('singular second format', () {
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final line = estimator1x.formatLine(
          durationSec: 1.0,
          bitrateKbps: 256,
          format: ExportFormat.mp4,
        );
        expect(line, 'Estimation — Export time 1 second — Output size 32.0KB');
      });

      test('formatLine with minute and second components', () {
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final line = estimator1x.formatLine(
          durationSec: 90.0,
          bitrateKbps: 256,
          format: ExportFormat.mp4,
        );
        expect(line,
            'Estimation — Export time 1 minute 30 seconds — Output size 2.8MB');
      });

      test('exactly 60s formats as "1 minute"', () {
        // 60.0s @ 1.0× → 60s → expect "1 minute" not "60 seconds"
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final line = estimator1x.formatLine(
          durationSec: 60.0,
          bitrateKbps: 1000,
          format: ExportFormat.mp4,
        );
        expect(line, contains('Export time 1 minute —'));
      });

      test('exactly 3600s formats as "1 hour"', () {
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final line = estimator1x.formatLine(
          durationSec: 3600.0,
          bitrateKbps: 1000,
          format: ExportFormat.mp4,
        );
        expect(line, contains('Export time 1 hour —'));
      });

      test('size in KB band → "X.XKB"', () {
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final line = estimator1x.formatLine(
          durationSec: 1.0,
          bitrateKbps: 128,
          format: ExportFormat.mp4,
        );
        expect(line, 'Estimation — Export time 1 second — Output size 16.0KB');
      });

      test('exactly 1MB worth of bytes formats as "1.0MB"', () {
        // 1MB = 1024 * 1024 bytes = 1048576 bytes
        // bitrateKbps × durationSec / 8 × 1024 = 1048576
        // → bitrateKbps × durationSec = 8192
        // Use 8192 kbps × 1.0s (uses binary 1024)
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final line = estimator1x.formatLine(
          durationSec: 1.0,
          bitrateKbps: 8192,
          format: ExportFormat.mp4,
        );
        expect(line, contains('— Output size 1.0MB'));
      });

      test('size in GB band → "X.XGB"', () {
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final line = estimator1x.formatLine(
          durationSec: 3600.0,
          bitrateKbps: 100000,
          format: ExportFormat.mp4,
        );
        expect(line, 'Estimation — Export time 1 hour — Output size 42.9GB');
      });

      test('format=GIF affects size only, not time', () {
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final lineMP4 = estimator1x.formatLine(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.mp4,
        );
        final lineGIF = estimator1x.formatLine(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.gif,
        );
        // Extract time part (should be identical)
        final timeRegex = RegExp(r'Export time (.+) — Output');
        final timeMP4 = timeRegex.firstMatch(lineMP4)?.group(1);
        final timeGIF = timeRegex.firstMatch(lineGIF)?.group(1);
        expect(timeMP4, timeGIF);
      });

      test('very large bitrate + duration → handles size formatting correctly', () {
        const estimator1x = ExportEstimator(lastRealtimeMultiplier: 1.0);
        final line = estimator1x.formatLine(
          durationSec: 300.0,
          bitrateKbps: 50000,
          format: ExportFormat.mp4,
        );
        expect(line, 'Estimation — Export time 5 minutes — Output size 1.8GB');
      });
    });

    group('default multiplier', () {
      test('default lastRealtimeMultiplier is 0.7', () {
        const defaultEstimator = ExportEstimator();
        expect(defaultEstimator.lastRealtimeMultiplier, 0.7);
      });
    });
  });
}
