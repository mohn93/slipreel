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

  /// Load cursor data from file
  static Future<CursorRecording> loadFromFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('Cursor file not found: $filePath');
      }

      final content = await file.readAsString();
      final jsonData = jsonDecode(content) as List;

      final recording = CursorRecording();
      for (final item in jsonData) {
        recording.addPosition(CursorPosition.fromJson(item as Map<String, dynamic>));
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
