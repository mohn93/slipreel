// packages/slipreel_engine/test/models/camera_sidecar_meta_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_sidecar_meta.dart';

void main() {
  test('json round-trips', () {
    const m = CameraSidecarMeta(
      deviceLabel: 'FaceTime HD', width: 1280, height: 720,
      frameCount: 300, offsetMicros: 12000, selfViewX: 0.8, selfViewY: 0.75);
    final back = CameraSidecarMeta.fromJson(jsonDecode(jsonEncode(m.toJson())));
    expect(back, m);
  });

  test('saveForVideo writes <video>.camera.json then loads back', () async {
    final dir = await Directory.systemTemp.createTemp('cam_meta');
    final video = '${dir.path}/r.mp4';
    const m = CameraSidecarMeta(
      deviceLabel: 'Cam', width: 640, height: 480,
      frameCount: 10, offsetMicros: 0, selfViewX: 0.5, selfViewY: 0.5);
    await m.saveForVideo(video);
    final f = File('$video.camera.json');
    expect(f.existsSync(), isTrue);
    final loaded = await CameraSidecarMeta.loadForVideo(video);
    expect(loaded, m);
    await dir.delete(recursive: true);
  });

  test('loadForVideo returns null when absent', () async {
    final loaded = await CameraSidecarMeta.loadForVideo('/no/such/file.mp4');
    expect(loaded, isNull);
  });

  test('loadForVideo returns null for corrupt file', () async {
    final dir = await Directory.systemTemp.createTemp('cam_corrupt');
    final video = '${dir.path}/r.mp4';
    await File('$video.camera.json').writeAsString('NOT JSON {{{');
    expect(await CameraSidecarMeta.loadForVideo(video), isNull);
    await dir.delete(recursive: true);
  });
}
