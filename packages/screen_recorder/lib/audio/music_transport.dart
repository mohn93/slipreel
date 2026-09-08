/// Tracks transport commands, not the audio player's delayed position polls.
/// Both native players run at the requested rate between commands. Comparing
/// their independently polled clocks every frame creates audible seek loops.
class MusicTransport {
  Duration? _position;
  Duration? _time;
  bool _playing = false;
  double _speed = 1;
  int? _seekRevision;

  bool needsSeek({
    required Duration position,
    required Duration now,
    required bool playing,
    required double speed,
    required int seekRevision,
  }) {
    final previous = _position;
    final elapsed = _time == null ? Duration.zero : now - _time!;
    final expected = previous == null
        ? position
        : previous +
              (_playing
                  ? Duration(
                      microseconds: (elapsed.inMicroseconds * _speed).round(),
                    )
                  : Duration.zero);
    final seek =
        previous == null ||
        playing != _playing ||
        seekRevision != _seekRevision ||
        (!playing && position != previous) ||
        (playing && (position - expected).inMilliseconds.abs() > 250);
    _position = position;
    _time = now;
    _playing = playing;
    _speed = speed;
    _seekRevision = seekRevision;
    return seek;
  }
}
