import 'dart:io';
import 'dart:convert';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Stores cursor position data for a recording session
class CursorRecording {
  final List<CursorPosition> _positions = [];

  /// Get unmodifiable view of positions
  List<CursorPosition> get positions => List.unmodifiable(_positions);

  /// Add a cursor position to the recording
  void addPosition(CursorPosition position) {
    _positions.add(position);
  }

  /// Get cursor position at specific timestamp (interpolated if needed)
  CursorPosition? getPositionAt(int timestampMicros) {
    if (_positions.isEmpty) return null;

    // Binary search to find insertion point
    int low = 0;
    int high = _positions.length - 1;

    while (low <= high) {
      int mid = (low + high) ~/ 2;
      if (_positions[mid].timestampMicros == timestampMicros) {
        return _positions[mid];
      } else if (_positions[mid].timestampMicros < timestampMicros) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    // Now low is the insertion point
    CursorPosition? after = low < _positions.length ? _positions[low] : null;
    CursorPosition? before = high >= 0 ? _positions[high] : null;

    if (before == null) return after;
    if (after == null) return before;

    // Division by zero check
    if (before.timestampMicros == after.timestampMicros) {
      return before;
    }

    // Interpolate
    final t = (timestampMicros - before.timestampMicros) /
              (after.timestampMicros - before.timestampMicros);

    return CursorPosition(
      x: before.x + (after.x - before.x) * t,
      y: before.y + (after.y - before.y) * t,
      timestampMicros: timestampMicros,
      isClicked: before.isClicked || after.isClicked,
      // State is a discrete attribute — we can't interpolate
      // "halfway between arrow and I-beam". Use the closer sample's
      // state so a transition flips at t=0.5 rather than averaging
      // to nonsense.
      state: t < 0.5 ? before.state : after.state,
    );
  }

  /// Save cursor data to file
  Future<void> saveToFile(String filePath) async {
    try {
      final file = File(filePath);
      final jsonData = _positions.map((p) => p.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonData));
    } catch (e) {
      throw Exception('Failed to save cursor data: $e');
    }
  }

  /// Load cursor data from file.
  ///
  /// Detects the timestamp format and only rebases legacy recordings.
  /// New recordings store timestamps as microseconds since the first
  /// video frame's capture time (small values, typically 0–7 seconds
  /// for a short clip). Legacy recordings (made before the native
  /// plugin rebased to video-relative time) stored
  /// `mach_absolute_time()` values — billions of microseconds since
  /// boot. We tell them apart by magnitude: if the first sample's
  /// timestamp is implausibly large for a single recording (>1 minute),
  /// it's legacy and gets rebased to start at zero. Otherwise the
  /// timestamps are already video-relative and we use them as-is —
  /// rebasing them would destructively shift every sample forward by
  /// the warmup gap (typically 100–400 ms while SCStream produces its
  /// first frame), so editor lookups at video time t return the cursor
  /// position from t + gap and the focal/cyan-dot lead the actual
  /// cursor sprite.
  static const int _legacyTimestampThresholdMicros = 60 * 1000 * 1000;

  static Future<CursorRecording> loadFromFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('Cursor file not found: $filePath');
      }

      final content = await file.readAsString();
      final jsonData = jsonDecode(content) as List;

      final recording = CursorRecording();
      if (jsonData.isEmpty) return recording;

      final raw = jsonData
          .map((m) => CursorPosition.fromJson(m as Map<String, dynamic>))
          .toList(growable: false);
      final isLegacy =
          raw.first.timestampMicros > _legacyTimestampThresholdMicros;
      final base = isLegacy ? raw.first.timestampMicros : 0;
      for (final p in raw) {
        recording.addPosition(CursorPosition(
          x: p.x,
          y: p.y,
          timestampMicros: p.timestampMicros - base,
          isClicked: p.isClicked,
          state: p.state,
        ));
      }

      return recording;
    } catch (e) {
      throw Exception('Failed to load cursor data: $e');
    }
  }

  /// Get total number of positions
  int get count => _positions.length;

  /// Clear all positions
  void clear() {
    _positions.clear();
  }
}
