/// Pure helpers that slave the camera `.camera.mov` player to the main
/// screen player. `screen_time = camera_time + offsetMicros`, so the camera
/// position for a given screen playhead is `main − offset`, clamped to the
/// camera's own duration.
class CameraPlaybackSync {
  const CameraPlaybackSync._();

  /// Default re-seek threshold. Below this drift the two players are
  /// considered in sync (video_player position granularity is ~frame-level,
  /// so a small tolerance avoids thrashing seeks every tick).
  static const Duration defaultThreshold = Duration(milliseconds: 60);

  static Duration desiredCameraPosition({
    required Duration mainPosition,
    required int offsetMicros,
    required Duration cameraDuration,
  }) {
    final raw = mainPosition.inMicroseconds - offsetMicros;
    final clamped = raw < 0
        ? 0
        : (raw > cameraDuration.inMicroseconds
            ? cameraDuration.inMicroseconds
            : raw);
    return Duration(microseconds: clamped);
  }

  static bool shouldSeek({
    required Duration current,
    required Duration desired,
    Duration threshold = defaultThreshold,
  }) {
    final drift = (current.inMicroseconds - desired.inMicroseconds).abs();
    return drift > threshold.inMicroseconds;
  }
}
