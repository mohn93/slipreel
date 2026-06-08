import 'dart:async';
import 'dart:typed_data';

/// Maps export output source-time to the time-aligned camera frame.
///
/// The camera movie is decoded as a constant-fps (`fps`) BGRA stream and
/// consumed monotonically. For an output frame at source-time `t`, the aligned
/// camera frame index is `round(t*fps) - offsetFrames`, where
/// `offsetFrames = round(offsetMicros*fps/1e6)` (screen_time = camera_time +
/// offsetMicros). Returns null before the camera starts, after it ends, or once
/// a decode error has disabled the source.
class CameraFrameSource {
  CameraFrameSource({
    required Stream<Uint8List> frames,
    required this.fps,
    required int offsetMicros,
  })  : _it = StreamIterator(frames),
        _offsetFrames = (offsetMicros * fps / 1e6).round();

  final int fps;
  final int _offsetFrames;
  final StreamIterator<Uint8List> _it;

  int _consumed = -1; // index of the frame currently in _current
  Uint8List? _current;
  bool _exhausted = false;
  bool _failed = false;

  bool get failed => _failed;

  /// The aligned camera frame for output source-time [t], or null when hidden
  /// (before start / after end / source failed).
  Future<Uint8List?> frameAt(Duration t) async {
    if (_failed) return null;
    final target = (t.inMicroseconds * fps / 1e6).round() - _offsetFrames;
    if (target < 0) return null;
    while (_consumed < target && !_exhausted) {
      try {
        if (!await _it.moveNext()) {
          _exhausted = true;
          break;
        }
        _current = _it.current;
        _consumed++;
      } catch (_) {
        _failed = true;
        _current = null;
        return null;
      }
    }
    if (_consumed < target) return null; // ran past the end
    return _current;
  }

  Future<void> dispose() => _it.cancel();
}
