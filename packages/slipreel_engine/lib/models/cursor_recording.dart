import 'dart:io';
import 'dart:convert';
import 'package:flutter/painting.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Stores cursor position data for a recording session
class CursorRecording {
  final List<CursorPosition> _positions = [];
  int _version = 0;
  CursorEventIndex? _eventIndexCache;
  int? _eventIndexVersion;

  /// Get unmodifiable view of positions
  List<CursorPosition> get positions => List.unmodifiable(_positions);

  /// Add a cursor position to the recording
  void addPosition(CursorPosition position) {
    _positions.add(position);
    _version++;
  }

  /// Indexed click/release events derived from the recording. Lazily
  /// built on first access, cached, and invalidated whenever the
  /// recording mutates ([addPosition] / [clear]). Painters and the
  /// press-pulse spring used to walk the entire `_positions` list
  /// from the start every frame to find the most recent click —
  /// O(N) per call × 3 painters × 60 fps was wasted work on every
  /// recording of any length. The index sorts events into two short
  /// arrays and answers via binary search.
  CursorEventIndex get eventIndex {
    if (_eventIndexCache == null || _eventIndexVersion != _version) {
      _eventIndexCache = CursorEventIndex._fromPositions(_positions);
      _eventIndexVersion = _version;
    }
    return _eventIndexCache!;
  }

  /// Get cursor position at the given timestamp.
  ///
  /// Default behavior linearly interpolates between the two
  /// surrounding recorded samples — gives smooth sub-frame motion when
  /// the editor's frame timing doesn't align exactly with the 60 Hz
  /// recorder. Pass `nearestSample: true` to skip interpolation and
  /// return the closer of the two surrounding samples instead — used
  /// by the None ("snap") cursor preset so the rendered cursor lands
  /// on the exact recorded grid with no in-between smoothing.
  CursorPosition? getPositionAt(
    int timestampMicros, {
    bool nearestSample = false,
  }) {
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

    if (nearestSample) {
      final distBefore = timestampMicros - before.timestampMicros;
      final distAfter = after.timestampMicros - timestampMicros;
      return distBefore <= distAfter ? before : after;
    }

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
    _version++;
  }
}

/// One click event extracted from a [CursorRecording] — the timestamp
/// of the false→true `isClicked` transition and the cursor's
/// screen-space position at that moment. Stored in [CursorEventIndex]
/// so the press-pulse can find "which click most recently happened
/// at or before time t" without walking the recording every frame.
class CursorClickEvent {
  const CursorClickEvent({
    required this.timestampMicros,
    required this.screenPos,
  });
  final int timestampMicros;
  final Offset screenPos;
}

/// Pre-extracted click / release event lists with sorted timestamps,
/// answering "what's the most recent click/release at or before t?"
/// in O(log N) via binary search. Built lazily by
/// [CursorRecording.eventIndex] and invalidated on mutation.
class CursorEventIndex {
  CursorEventIndex._fromPositions(List<CursorPosition> positions) {
    bool? prevClicked;
    for (final p in positions) {
      if (prevClicked == false && p.isClicked) {
        _clickMicros.add(p.timestampMicros);
        _clickPositions.add(Offset(p.x, p.y));
      } else if (prevClicked == true && !p.isClicked) {
        _releaseMicros.add(p.timestampMicros);
      }
      prevClicked = p.isClicked;
    }
  }

  final List<int> _clickMicros = <int>[];
  final List<Offset> _clickPositions = <Offset>[];
  final List<int> _releaseMicros = <int>[];

  /// Most recent click event at or before [timestampMicros], or null
  /// when no click has happened yet at that playhead.
  CursorClickEvent? lastClickAtOrBefore(int timestampMicros) {
    final idx = _floorIndex(_clickMicros, timestampMicros);
    if (idx < 0) return null;
    return CursorClickEvent(
      timestampMicros: _clickMicros[idx],
      screenPos: _clickPositions[idx],
    );
  }

  /// Timestamp of the most recent button-release at or before
  /// [timestampMicros], or null when the button has never been
  /// released by then.
  int? lastReleaseAtOrBefore(int timestampMicros) {
    final idx = _floorIndex(_releaseMicros, timestampMicros);
    if (idx < 0) return null;
    return _releaseMicros[idx];
  }

  /// Returns the largest index `i` such that `sorted[i] <= target`,
  /// or -1 when [target] is below every element. The input list is
  /// already sorted ascending because it was built by walking the
  /// recording in order. Standard floor-style binary search.
  static int _floorIndex(List<int> sorted, int target) {
    if (sorted.isEmpty || sorted.first > target) return -1;
    var lo = 0;
    var hi = sorted.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (sorted[mid] <= target) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// All click (press rising edge) timestamps from the recording,
  /// in source-time, sorted ascending. Returned list is unmodifiable.
  /// Built once per index instance and cached — cheap to call repeatedly.
  late final List<Duration> clickTimes = List<Duration>.unmodifiable(
    _clickMicros.map((m) => Duration(microseconds: m)),
  );
}
