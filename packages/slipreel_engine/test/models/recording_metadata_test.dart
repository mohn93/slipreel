@TestOn('vm')
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';

void main() {
  test('round-trips durationMs and writes schemaVersion 3', () {
    final meta = RecordingMetadata(
      isPureSource: true,
      recordedAt: DateTime.utc(2026, 5, 14, 19, 33, 40),
      widthPx: 2214,
      heightPx: 1984,
      fps: 60,
      duration: const Duration(milliseconds: 41823),
    );
    final json = meta.toJson();
    expect(json['durationMs'], 41823);
    expect(json['schemaVersion'], 3);

    final back = RecordingMetadata.fromJson(json);
    expect(back.duration, const Duration(milliseconds: 41823));
    expect(back.widthPx, 2214);
    expect(back.isPureSource, isTrue);
  });

  test('v1 sidecar (no durationMs) parses with duration == null', () {
    final v1 = {
      'isPureSource': true,
      'recordedAt': '2026-05-14T19:33:40.000Z',
      'widthPx': 2214,
      'heightPx': 1984,
      'fps': 60,
      'schemaVersion': 1,
    };
    final meta = RecordingMetadata.fromJson(v1);
    expect(meta.duration, isNull);
    expect(meta.fps, 60);
  });

  test('duration defaults to null when constructed without it', () {
    final meta = RecordingMetadata(
      isPureSource: false,
      recordedAt: DateTime.utc(1970),
      widthPx: 0,
      heightPx: 0,
      fps: 30,
    );
    expect(meta.duration, isNull);
    expect(meta.toJson().containsKey('durationMs'), isFalse);
  });

  test('round-trips isDeviceCapture', () {
    final meta = RecordingMetadata(
      isPureSource: true,
      recordedAt: DateTime.utc(2026, 6, 21),
      widthPx: 1170,
      heightPx: 2532,
      fps: 60,
      isDeviceCapture: true,
    );
    final back = RecordingMetadata.fromJson(meta.toJson());
    expect(back.isDeviceCapture, isTrue);
  });

  test('isDeviceCapture defaults to false when absent (legacy sidecar)', () {
    final back = RecordingMetadata.fromJson({
      'isPureSource': true,
      'recordedAt': '2026-06-21T00:00:00Z',
      'widthPx': 1920,
      'heightPx': 1080,
      'fps': 30,
      'schemaVersion': 2,
    });
    expect(back.isDeviceCapture, isFalse);
  });

  test('isDeviceCapture defaults to false when constructed without it', () {
    final meta = RecordingMetadata(
      isPureSource: false,
      recordedAt: DateTime.utc(1970),
      widthPx: 0,
      heightPx: 0,
      fps: 30,
    );
    expect(meta.isDeviceCapture, isFalse);
  });

  group('existing behavior preserved', () {
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
