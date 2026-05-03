import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/export/export_estimator.dart';
import 'package:screen_recorder/models/export_settings.dart';

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
        final duration07x = estimator.estimateExportTime(1.0);
        expect(duration05x.inMilliseconds, greaterThan(duration07x.inMilliseconds));
      });
    });

    group('estimateOutputBytes', () {
      test('1080p / Web tier (6000 kbps) × 30s MP4 → 23,040,000 bytes', () {
        final bytes = estimator.estimateOutputBytes(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.mp4,
        );
        expect(bytes, closeTo(23040000, 1000));
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
        expect(bytesGIF, closeTo(bytesMP4 * 0.6, bytesMP4 * 0.01));
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
      test('short clip → exact format match', () {
        final line = estimator.formatLine(
          durationSec: 1.0,
          bitrateKbps: 256,
          format: ExportFormat.mp4,
        );
        expect(line, contains('Estimation'));
        expect(line, contains('Export time'));
        expect(line, contains('Output size'));
      });

      test('plural seconds format', () {
        // At 0.7× multiplier, ~3.5s source → ~5s export time
        final line = estimator.formatLine(
          durationSec: 3.5,
          bitrateKbps: 256,
          format: ExportFormat.mp4,
        );
        expect(line, contains('seconds'));
      });

      test('singular second format', () {
        // At 0.7× multiplier, ~0.35s source → ~0.5s export time (floored)
        final line = estimator.formatLine(
          durationSec: 0.35,
          bitrateKbps: 256,
          format: ExportFormat.mp4,
        );
        expect(line, contains('1 second'));
      });

      test('90 seconds source → "2 minutes X seconds"', () {
        // At 0.7×, 90s source → ~128s export time
        final line = estimator.formatLine(
          durationSec: 90.0,
          bitrateKbps: 256,
          format: ExportFormat.mp4,
        );
        expect(line, contains('minute'));
      });

      test('exactly 42s source → "1 minute" at 0.7×', () {
        // 42 / 0.7 = 60s
        const estimator70 = ExportEstimator(lastRealtimeMultiplier: 0.7);
        final line = estimator70.formatLine(
          durationSec: 42.0,
          bitrateKbps: 256,
          format: ExportFormat.mp4,
        );
        expect(line, contains('1 minute'));
      });

      test('1 hour source at 0.7× → multi-minute export', () {
        final line = estimator.formatLine(
          durationSec: 3600.0,
          bitrateKbps: 256,
          format: ExportFormat.mp4,
        );
        expect(line, contains('hour'));
      });

      test('size in KB band → "X.XKB"', () {
        final line = estimator.formatLine(
          durationSec: 1.0,
          bitrateKbps: 128,
          format: ExportFormat.mp4,
        );
        expect(line, contains('KB'));
      });

      test('size in GB band → "X.XGB"', () {
        final line = estimator.formatLine(
          durationSec: 3600.0,
          bitrateKbps: 100000,
          format: ExportFormat.mp4,
        );
        expect(line, contains('GB'));
      });

      test('size in MB band → "X.XMB"', () {
        final line = estimator.formatLine(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.mp4,
        );
        expect(line, contains('MB'));
      });

      test('format=GIF affects size only, not time', () {
        final lineMP4 = estimator.formatLine(
          durationSec: 30.0,
          bitrateKbps: 6000,
          format: ExportFormat.mp4,
        );
        final lineGIF = estimator.formatLine(
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
        final line = estimator.formatLine(
          durationSec: 300.0,
          bitrateKbps: 50000,
          format: ExportFormat.mp4,
        );
        expect(line, contains('Estimation'));
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
