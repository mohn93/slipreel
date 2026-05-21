// packages/screen_recorder/test/models/recording_metadata_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';

void main() {
  group('RecordingMetadata', () {
    test('round-trips through JSON', () {
      final m = RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.parse('2026-04-28T10:00:00Z'),
        widthPx: 1920,
        heightPx: 1080,
        fps: 60,
      );
      final json = m.toJson();
      final restored = RecordingMetadata.fromJson(json);
      expect(restored.isPureSource, isTrue);
      expect(restored.widthPx, 1920);
      expect(restored.heightPx, 1080);
      expect(restored.fps, 60);
      expect(restored.recordedAt, m.recordedAt);
    });

    test('legacy returns isPureSource=false when sidecar missing', () async {
      final tmp = Directory.systemTemp.createTempSync('phase9_meta');
      final videoPath = '${tmp.path}/legacy.mp4';
      File(videoPath).writeAsBytesSync([0]);
      final m = await RecordingMetadata.loadForVideo(videoPath);
      expect(m.isPureSource, isFalse);
      tmp.deleteSync(recursive: true);
    });

    test('saves and reloads alongside video file', () async {
      final tmp = Directory.systemTemp.createTempSync('phase9_meta');
      final videoPath = '${tmp.path}/rec.mp4';
      File(videoPath).writeAsBytesSync([0]);
      final m = RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.parse('2026-04-28T10:00:00Z'),
        widthPx: 1920,
        heightPx: 1080,
        fps: 60,
      );
      await m.saveForVideo(videoPath);
      final loaded = await RecordingMetadata.loadForVideo(videoPath);
      expect(loaded.isPureSource, isTrue);
      expect(loaded.widthPx, 1920);
      tmp.deleteSync(recursive: true);
    });
  });
}
