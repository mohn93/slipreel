// packages/screen_recorder_platform_interface/test/models/recording_result_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('NativePerfStats parses from method-channel map', () {
    final map = <String, dynamic>{
      'droppedFrames': 3,
      'cpuPctSamples': <double>[1.0, 2.0, 3.0],
      'memBytesSamples': <int>[1000000, 2000000, 1500000],
    };
    final stats = NativePerfStats.fromMap(map);
    expect(stats.droppedFrames, 3);
    expect(stats.cpuPctSamples, [1.0, 2.0, 3.0]);
    expect(stats.memBytesPeak, 2000000);
  });

  test('RecordingResult parses from method-channel map', () {
    final map = <String, dynamic>{
      'outputPath': '/tmp/x.mp4',
      'droppedFrames': 0,
      'cpuPctSamples': <double>[],
      'memBytesSamples': <int>[],
    };
    final r = RecordingResult.fromMap(map);
    expect(r.outputPath, '/tmp/x.mp4');
    expect(r.perfStats.droppedFrames, 0);
  });
}
