// packages/screen_recorder/test/utils/perf_summary_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/utils/perf_summary.dart';

void main() {
  group('RecordingPerfSummary', () {
    test('format includes all key fields', () {
      const s = RecordingPerfSummary(
        durationSeconds: 60.0,
        frameCount: 3600,
        expectedFrameCount: 3600,
        droppedFrameCount: 5,
        cpuPctAvg: 4.2,
        cpuPctP95: 7.1,
        memPeakBytes: 84 * 1024 * 1024,
        outputBytes: 156000000,
        targetFps: 60,
      );
      final formatted = s.format();
      expect(formatted, contains('duration=60.0s'));
      expect(formatted, contains('frames=3600'));
      expect(formatted, contains('droppedFrames=5'));
      expect(formatted, contains('cpuPctAvg=4.2'));
      expect(formatted, contains('memPeakMB=84'));
      expect(formatted, contains('verdict'));
      expect(formatted, contains('PASS'));
    });

    test('verdict FAIL when CPU exceeds target', () {
      const s = RecordingPerfSummary(
        durationSeconds: 60.0,
        frameCount: 3600,
        expectedFrameCount: 3600,
        droppedFrameCount: 0,
        cpuPctAvg: 15.0,
        cpuPctP95: 22.0,
        memPeakBytes: 100 * 1024 * 1024,
        outputBytes: 100000000,
        targetFps: 60,
      );
      expect(s.format(), contains('FAIL'));
    });

    test('verdict FAIL when memory exceeds target', () {
      const s = RecordingPerfSummary(
        durationSeconds: 60.0,
        frameCount: 3600,
        expectedFrameCount: 3600,
        droppedFrameCount: 0,
        cpuPctAvg: 5.0,
        cpuPctP95: 8.0,
        memPeakBytes: 600 * 1024 * 1024,
        outputBytes: 100000000,
        targetFps: 60,
      );
      expect(s.format(), contains('FAIL'));
    });

    test('verdict FAIL when drop rate exceeds 1%', () {
      const s = RecordingPerfSummary(
        durationSeconds: 60.0,
        frameCount: 3600,
        expectedFrameCount: 3600,
        droppedFrameCount: 50,
        cpuPctAvg: 5.0,
        cpuPctP95: 8.0,
        memPeakBytes: 100 * 1024 * 1024,
        outputBytes: 100000000,
        targetFps: 60,
      );
      expect(s.format(), contains('FAIL'));
    });
  });

  group('ExportPerfSummary', () {
    test('format includes realtime multiple', () {
      const s = ExportPerfSummary(
        inputDurationSeconds: 60.0,
        wallTimeSeconds: 12.0,
        decodeMsPerFrame: 2.1,
        compositeMsPerFrame: 4.3,
        encodeMsPerFrame: 1.4,
        outputBytes: 85000000,
        outputCodec: 'h264_videotoolbox',
        usedHardwareEncoder: true,
      );
      final f = s.format();
      expect(f, contains('realtimeMultiple=5.0x'));
      expect(f, contains('HW encoder: yes'));
      expect(f, contains('PASS'));
    });

    test('verdict FAIL when slower than realtime', () {
      const s = ExportPerfSummary(
        inputDurationSeconds: 60.0,
        wallTimeSeconds: 90.0,
        decodeMsPerFrame: 5,
        compositeMsPerFrame: 15,
        encodeMsPerFrame: 10,
        outputBytes: 80000000,
        outputCodec: 'libx264',
        usedHardwareEncoder: false,
      );
      expect(s.format(), contains('FAIL'));
    });
  });
}
