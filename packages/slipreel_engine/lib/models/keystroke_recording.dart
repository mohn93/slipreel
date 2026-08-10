import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Stores keyboard events captured during a recording session.
///
/// Events are kept in chronological order. Binary search is used for
/// time-range queries so playback overlays stay O(log N) per frame.
class KeystrokeRecording {
  final List<KeystrokeEvent> _events = [];
  List<KeystrokeEvent>? _eventsSnapshot;

  int get count => _events.length;
  List<KeystrokeEvent> get events =>
      _eventsSnapshot ??= List.unmodifiable(_events);

  /// [eventsInRange] binary-searches assuming ascending timestamps, so
  /// ingestion enforces the invariant: in-order appends stay O(1); a
  /// late arrival takes the rare sorted-insert path instead of breaking
  /// range queries after the inversion.
  void addEvent(KeystrokeEvent event) {
    if (_events.isEmpty ||
        event.timestampMicros >= _events.last.timestampMicros) {
      _events.add(event);
      _eventsSnapshot = null;
      return;
    }
    var lo = 0, hi = _events.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_events[mid].timestampMicros <= event.timestampMicros) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _events.insert(lo, event);
    _eventsSnapshot = null;
  }

  void clear() {
    _events.clear();
    _eventsSnapshot = null;
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
    final snapshot = List<KeystrokeEvent>.of(_events, growable: false);
    await Isolate.run(() async {
      final buf = StringBuffer();
      for (final e in snapshot) {
        buf.writeln(jsonEncode(e.toJson()));
      }
      await File(path).writeAsString(buf.toString());
    });
  }

  static Future<KeystrokeRecording> loadFromFile(String path) async {
    // Parse in a worker isolate for the same reason as
    // CursorRecording.loadFromFile: long recordings produce sidecars big
    // enough for per-line JSON decoding to stall the UI isolate.
    final events = await Isolate.run(() => _parseSidecar(path));
    final recording = KeystrokeRecording();
    recording._events.addAll(events);
    return recording;
  }

  /// Pure parse stage of [loadFromFile] — runs inside [Isolate.run].
  static Future<List<KeystrokeEvent>> _parseSidecar(String path) async {
    final lines = await File(path).readAsLines();
    final events = <KeystrokeEvent>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final json = jsonDecode(trimmed) as Map<String, dynamic>;
        events.add(KeystrokeEvent.fromJson(json));
      } catch (_) {
        // Skip malformed lines.
      }
    }
    events.sort((a, b) => a.timestampMicros.compareTo(b.timestampMicros));
    return events;
  }
}
