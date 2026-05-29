import 'dart:convert';
import 'dart:io';

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Append-only NDJSON sidecar of cursor positions written during a recording.
/// Buffers positions in memory; flushes on a 256-entry threshold and on stop.
/// Sub-project C uses this to restore the cursor track on crash recovery.
///
/// Wire format (one position per line):
/// `{"x":120.5,"y":340.0,"tUs":1234567,"clk":true,"st":"arrow"}`
class CursorCheckpointer {
  CursorCheckpointer({required this.ndjsonPath});
  final String ndjsonPath;

  static const _flushThreshold = 256;

  RandomAccessFile? _raf;
  final List<String> _buffer = [];

  /// Open the file for write (truncates any existing content).
  Future<void> start() async {
    final file = File(ndjsonPath);
    if (!file.parent.existsSync()) {
      await file.parent.create(recursive: true);
    }
    // FileMode.write truncates existing content.
    _raf = await file.open(mode: FileMode.write);
  }

  /// Buffer a single position. Flushes synchronously if the buffer reaches
  /// the threshold so data reaches disk before [stop] is called.
  void add(CursorPosition pos) {
    _buffer.add(jsonEncode({
      'x': pos.x,
      'y': pos.y,
      'tUs': pos.timestampMicros,
      'clk': pos.isClicked,
      'st': pos.state.name,
    }));
    if (_buffer.length >= _flushThreshold) {
      _flushSync();
    }
  }

  /// Flush any remaining buffer entries and close the file.
  Future<void> stop() async {
    _flushSync();
    await _raf?.close();
    _raf = null;
  }

  void _flushSync() {
    if (_buffer.isEmpty || _raf == null) return;
    final chunk = _buffer.map((l) => '$l\n').join();
    _raf!.writeStringSync(chunk);
    _buffer.clear();
  }

  /// Read the NDJSON file back into a list of positions. Returns empty if the
  /// file is missing or unreadable.
  static Future<List<CursorPosition>> readAll(String path) async {
    final file = File(path);
    if (!file.existsSync()) return const [];
    final raw = await file.readAsString();
    final out = <CursorPosition>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final m = jsonDecode(trimmed) as Map<String, dynamic>;
        out.add(CursorPosition(
          x: (m['x'] as num).toDouble(),
          y: (m['y'] as num).toDouble(),
          timestampMicros: (m['tUs'] as num).toInt(),
          isClicked: (m['clk'] as bool?) ?? false,
          state: CursorState.values
              .firstWhere((e) => e.name == m['st'], orElse: () => CursorState.arrow),
        ));
      } catch (_) {
        // Skip malformed lines (e.g. a truncated last line from a crash).
      }
    }
    return out;
  }
}
