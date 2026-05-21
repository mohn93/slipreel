// packages/screen_recorder/lib/models/recording_metadata.dart
import 'dart:convert';
import 'dart:io';

/// Sidecar metadata stored next to a recorded MP4 as
/// `<videopath>.meta.json`.
///
/// `isPureSource: true` means the video contains the raw capture only —
/// cursor and effects are stored separately and applied as overlays at
/// preview time and composited at export. `false` (or missing sidecar)
/// means a pre-Phase-9 recording where cursor is already baked in.
class RecordingMetadata {
  final bool isPureSource;
  final DateTime recordedAt;
  final int widthPx;
  final int heightPx;
  final int fps;

  const RecordingMetadata({
    required this.isPureSource,
    required this.recordedAt,
    required this.widthPx,
    required this.heightPx,
    required this.fps,
  });

  Map<String, dynamic> toJson() => {
        'isPureSource': isPureSource,
        'recordedAt': recordedAt.toUtc().toIso8601String(),
        'widthPx': widthPx,
        'heightPx': heightPx,
        'fps': fps,
        'schemaVersion': 1,
      };

  factory RecordingMetadata.fromJson(Map<String, dynamic> json) {
    return RecordingMetadata(
      isPureSource: json['isPureSource'] as bool? ?? false,
      recordedAt:
          DateTime.parse(json['recordedAt'] as String? ?? '1970-01-01T00:00:00Z'),
      widthPx: json['widthPx'] as int? ?? 0,
      heightPx: json['heightPx'] as int? ?? 0,
      fps: json['fps'] as int? ?? 30,
    );
  }

  static String _sidecarPath(String videoPath) => '$videoPath.meta.json';

  Future<void> saveForVideo(String videoPath) async {
    final file = File(_sidecarPath(videoPath));
    await file.writeAsString(jsonEncode(toJson()));
  }

  /// Loads the sidecar for [videoPath], returning a legacy default
  /// (`isPureSource: false`) if the sidecar does not exist.
  static Future<RecordingMetadata> loadForVideo(String videoPath) async {
    final file = File(_sidecarPath(videoPath));
    if (!await file.exists()) {
      return RecordingMetadata(
        isPureSource: false,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(0),
        widthPx: 0,
        heightPx: 0,
        fps: 30,
      );
    }
    final content = await file.readAsString();
    return RecordingMetadata.fromJson(
        jsonDecode(content) as Map<String, dynamic>);
  }
}
