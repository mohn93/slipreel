import 'dart:convert';
import 'dart:io';

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Stores keyboard events captured during a recording session.
///
/// Events are kept in chronological order. Binary search is used for
/// time-range queries so playback overlays stay O(log N) per frame.
class KeystrokeRecording {
  final List<KeystrokeEvent> _events = [];

  int get count => _events.length;
  List<KeystrokeEvent> get events => List.unmodifiable(_events);

  void addEvent(KeystrokeEvent event) {
    _events.add(event);
  }

  void clear() {
    _events.clear();
  }

  /// All events whose timestamp falls in the range
  /// [startMicros, endMicros] (inclusive).
  List<KeystrokeEvent> eventsInRange(int startMicros, int endMicros) {
    if (_events.isEmpty) return const [];

    // Binary search for the first event >= startMicros.
    int lo = 0, hi = _events.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_events[mid].timestampMicros < startMicros) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }

    final result = <KeystrokeEvent>[];
    for (var i = lo; i < _events.length; i++) {
      if (_events[i].timestampMicros > endMicros) break;
      result.add(_events[i]);
    }
    return result;
  }

  Future<void> saveToFile(String path) async {
    final buf = StringBuffer();
    for (final e in _events) {
      buf.writeln(jsonEncode(e.toJson()));
    }
    await File(path).writeAsString(buf.toString());
  }

  static Future<KeystrokeRecording> loadFromFile(String path) async {
    final recording = KeystrokeRecording();
    final lines = await File(path).readAsLines();
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final json = jsonDecode(trimmed) as Map<String, dynamic>;
        recording.addEvent(KeystrokeEvent.fromJson(json));
      } catch (_) {
        // Skip malformed lines.
      }
    }
    return recording;
  }
}
