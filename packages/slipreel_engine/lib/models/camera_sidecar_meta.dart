import 'dart:convert';
import 'dart:io';

/// Metadata for a recorded camera sidecar, persisted as `<video>.camera.json`.
/// Its presence is the editor's signal that a `<video>.camera.mov` exists and a
/// camera track can be shown. The actual video lives in the .camera.mov.
class CameraSidecarMeta {
  final String deviceLabel;
  final int width;
  final int height;
  final int frameCount;

  /// Microseconds to add to a camera-track time to reach screen-track time.
  final int offsetMicros;

  /// Self-view final center, normalized (0..1) in canvas space, top-left origin.
  final double selfViewX;
  final double selfViewY;

  const CameraSidecarMeta({
    required this.deviceLabel,
    required this.width,
    required this.height,
    required this.frameCount,
    required this.offsetMicros,
    required this.selfViewX,
    required this.selfViewY,
  });

  Map<String, dynamic> toJson() => {
        'deviceLabel': deviceLabel,
        'width': width,
        'height': height,
        'frameCount': frameCount,
        'offsetMicros': offsetMicros,
        'selfViewX': selfViewX,
        'selfViewY': selfViewY,
      };

  factory CameraSidecarMeta.fromJson(Map<String, dynamic> json) => CameraSidecarMeta(
        deviceLabel: json['deviceLabel'] as String? ?? 'Camera',
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        frameCount: (json['frameCount'] as num?)?.toInt() ?? 0,
        offsetMicros: (json['offsetMicros'] as num?)?.toInt() ?? 0,
        selfViewX: (json['selfViewX'] as num?)?.toDouble() ?? 0.82,
        selfViewY: (json['selfViewY'] as num?)?.toDouble() ?? 0.82,
      );

  /// Path of the camera video for a given screen video path.
  static String moviePathForVideo(String videoPath) => '$videoPath.camera.mov';

  Future<void> saveForVideo(String videoPath) async {
    final file = File('$videoPath.camera.json');
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode(toJson()));
  }

  static Future<CameraSidecarMeta?> loadForVideo(String videoPath) async {
    final file = File('$videoPath.camera.json');
    if (!file.existsSync()) return null;
    try {
      return CameraSidecarMeta.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CameraSidecarMeta &&
      other.deviceLabel == deviceLabel &&
      other.width == width &&
      other.height == height &&
      other.frameCount == frameCount &&
      other.offsetMicros == offsetMicros &&
      other.selfViewX == selfViewX &&
      other.selfViewY == selfViewY;

  @override
  int get hashCode => Object.hash(
      deviceLabel, width, height, frameCount, offsetMicros, selfViewX, selfViewY);
}
