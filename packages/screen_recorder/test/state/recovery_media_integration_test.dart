import 'dart:io';
import 'dart:convert';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/camera_sidecar_meta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recovery_service.dart';
import 'package:screen_recorder/state/session_marker.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('recovery must preserve both mic and system audio', () async {
    final dir = Directory.systemTemp.createTempSync('review-recovery-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final source = '${dir.path}/source.mp4';
    final ffmpeg = Ffmpeg.resolve();
    final generated = await Process.run(ffmpeg, [
      '-y',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=s=64x64:r=10:d=1',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=1',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=880:duration=1',
      '-map',
      '0:v',
      '-map',
      '1:a',
      '-map',
      '2:a',
      '-c:v',
      'mpeg4',
      '-c:a',
      'aac',
      '-movflags',
      'frag_keyframe+empty_moov',
      source,
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    final camera = await Process.run(ffmpeg, [
      '-y',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=s=64x64:r=10:d=1',
      '-c:v',
      'mpeg4',
      '-movflags',
      'frag_keyframe+empty_moov',
      '$source.camera.mov',
    ]);
    expect(camera.exitCode, 0, reason: '${camera.stderr}');
    await File('$source.start-time').writeAsString('100');
    await File('$source.camera.mov.start-time').writeAsString('100.25');
    final marker = SessionMarker(
      id: 'review',
      videoPath: source,
      cursorNdjsonPath: '${dir.path}/cursor.ndjson',
      startedAt: DateTime.now(),
      width: 64,
      height: 64,
      fps: 10,
      isDeviceCapture: true,
      cameraDeviceLabel: 'Recovery camera',
    );
    final store = SessionMarkerStore(path: '${dir.path}/markers.json');
    await store.add(marker);
    final service = RecoveryService(markerStore: store);
    final out = await service.recover(
      RecoveryCandidate(marker: marker, videoBytes: File(source).lengthSync()),
      RecordingHistoryStore.inMemory([]),
    );
    expect(out, isNotNull);
    final probe = await Process.run(Ffmpeg.resolveProbe(), [
      '-v',
      'error',
      '-select_streams',
      'a',
      '-show_entries',
      'stream=index',
      '-of',
      'json',
      out!,
    ]);
    final tracks =
        (jsonDecode(probe.stdout as String)['streams'] as List).length;
    expect(File(source).existsSync(), isFalse);
    expect((await RecordingMetadata.loadForVideo(out)).isDeviceCapture, isTrue);
    final cameraMeta = await CameraSidecarMeta.loadForVideo(out);
    expect(cameraMeta!.offsetMicros, 250000);
    expect(cameraMeta.deviceLabel, 'Recovery camera');
    expect(cameraMeta.width, 64);
    expect(File('$out.camera.mov').existsSync(), isTrue);
    expect(File('$source.camera.mov').existsSync(), isFalse);
    expect(
      tracks,
      2,
      reason: 'Recovery should preserve both independent audio tracks',
    );
  });
}
