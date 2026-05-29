// packages/screen_recorder/lib/state/session_marker.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

class SessionMarker {
  const SessionMarker({
    required this.id,
    required this.videoPath,
    required this.cursorNdjsonPath,
    required this.startedAt,
    required this.width,
    required this.height,
    required this.fps,
  });

  final String id;
  final String videoPath;
  final String cursorNdjsonPath;
  final DateTime startedAt;
  final int width;
  final int height;
  final int fps;

  Map<String, dynamic> toJson() => {
        'id': id,
        'videoPath': videoPath,
        'cursorNdjsonPath': cursorNdjsonPath,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'width': width,
        'height': height,
        'fps': fps,
      };

  static SessionMarker fromJson(Map<String, dynamic> json) => SessionMarker(
        id: json['id'] as String,
        videoPath: json['videoPath'] as String,
        cursorNdjsonPath: json['cursorNdjsonPath'] as String,
        startedAt: DateTime.parse(json['startedAt'] as String),
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        fps: (json['fps'] as num?)?.toInt() ?? 0,
      );
}

/// Atomic JSON store at `<App Support>/current_sessions.json`.
///
/// All mutations read → mutate → write `<path>.tmp` → POSIX-rename onto
/// `<path>`. The canonical file is therefore either fully written or
/// untouched — never half-written.
class SessionMarkerStore {
  SessionMarkerStore({required this.path});
  final String path;

  static const _version = 1;

  Future<List<SessionMarker>> load() async {
    try {
      final file = File(path);
      if (!file.existsSync()) return const [];
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final sessions = (json['sessions'] as List?) ?? const [];
      return sessions
          .map((s) => SessionMarker.fromJson(s as Map<String, dynamic>))
          .toList(growable: false);
    } catch (e, st) {
      AppLogger.platform.w('SessionMarkerStore.load failed; treating as empty',
          error: e, stackTrace: st);
      return const [];
    }
  }

  Future<void> add(SessionMarker marker) async {
    final current = await load();
    await _atomicWrite([...current, marker]);
  }

  Future<void> remove(String id) async {
    final current = await load();
    await _atomicWrite(current.where((m) => m.id != id).toList(growable: false));
  }

  Future<void> _atomicWrite(List<SessionMarker> markers) async {
    final tmpPath = '$path.tmp';
    final json = {
      'version': _version,
      'sessions': markers.map((m) => m.toJson()).toList(growable: false),
    };
    final tmpFile = File(tmpPath);
    await tmpFile.create(recursive: true);
    await tmpFile.writeAsString(jsonEncode(json), flush: true);
    await tmpFile.rename(path);
  }
}

final sessionMarkerStoreProvider = Provider<SessionMarkerStore>(
  (ref) => throw UnimplementedError('Override sessionMarkerStoreProvider in main()'),
);
