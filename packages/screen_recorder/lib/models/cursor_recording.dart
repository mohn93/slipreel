import 'dart:io';
import 'dart:convert';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Stores cursor position data for a recording session
class CursorRecording {
  final List<CursorPosition> positions = [];

  /// Add a cursor position to the recording
  void addPosition(CursorPosition position) {
    positions.add(position);
  }

  /// Get cursor position at specific timestamp (interpolated if needed)
  CursorPosition? getPositionAt(int timestampMicros) {
    if (positions.isEmpty) return null;

    // Find two positions surrounding the timestamp
    CursorPosition? before;
    CursorPosition? after;

    for (final pos in positions) {
      if (pos.timestampMicros <= timestampMicros) {
        if (before == null || pos.timestampMicros > before.timestampMicros) {
          before = pos;
        }
      }
      if (pos.timestampMicros >= timestampMicros) {
        if (after == null || pos.timestampMicros < after.timestampMicros) {
          after = pos;
        }
      }
    }

    // If exact match, return it
    if (before != null && before.timestampMicros == timestampMicros) {
      return before;
    }

    // If only one side, return that
    if (before == null) return after;
    if (after == null) return before;

    // Interpolate between before and after
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
    final file = File(filePath);
    final jsonData = positions.map((p) => p.toJson()).toList();
    await file.writeAsString(jsonEncode(jsonData));
  }

  /// Load cursor data from file
  static Future<CursorRecording> loadFromFile(String filePath) async {
    final file = File(filePath);
    final content = await file.readAsString();
    final jsonData = jsonDecode(content) as List;

    final recording = CursorRecording();
    for (final item in jsonData) {
      recording.addPosition(CursorPosition.fromJson(item as Map<String, dynamic>));
    }

    return recording;
  }

  /// Get total number of positions
  int get count => positions.length;

  /// Clear all positions
  void clear() {
    positions.clear();
  }
}
