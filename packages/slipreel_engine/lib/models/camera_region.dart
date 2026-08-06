/// One span on the camera timeline lane where the bubble is visible.
///
/// Geometry is **placement + scale**, not a rect: [centerX]/[centerY] are
/// normalized (0..1, top-left origin) positions on the output canvas and
/// [size] is the bubble width as a fraction of canvas width. The rendered
/// height is derived from the GLOBAL `CameraShape`'s pixel-aspect, so the
/// per-region data never encodes aspect (matching the locked decision that
/// shape/roundness/style are global).
///
/// Time mirrors `ZoomRegion`: [startTime] + [duration], half-open
/// `[startTime, endTime)`.
class CameraRegion {
  static int _idCounter = 0;
  static int _nextId() => _idCounter++;

  /// Transient per-session identity: unique per constructed region and
  /// preserved through [copyWith]. Mirrors `ZoomRegion.id` — the camera
  /// lane keys its pill widgets on it so deleting a region doesn't re-bind
  /// the surviving pills' elements (and their position tweens) to a
  /// neighbour's data. Excluded from [==]/[hashCode] and JSON.
  final int id;

  final Duration startTime;
  final Duration duration;
  final double centerX;
  final double centerY;
  final double size;

  CameraRegion({
    required this.startTime,
    required this.duration,
    required double centerX,
    required double centerY,
    required double size,
    int? id,
  })  : assert(duration > Duration.zero, 'duration must be positive'),
        id = id ?? _nextId(),
        centerX = centerX.clamp(0.0, 1.0),
        centerY = centerY.clamp(0.0, 1.0),
        // A zero/negative size would render an invisible bubble the user
        // can't grab; clamp to a small floor.
        size = size.clamp(0.02, 1.0);

  Duration get endTime => startTime + duration;

  /// Half-open `[startTime, endTime)` — matches `ZoomRegion.isActive`, so a
  /// shared edge resolves to the later region with no one-frame ambiguity.
  bool isActive(Duration position) =>
      position >= startTime && position < endTime;

  CameraRegion copyWith({
    Duration? startTime,
    Duration? duration,
    double? centerX,
    double? centerY,
    double? size,
  }) =>
      CameraRegion(
        startTime: startTime ?? this.startTime,
        duration: duration ?? this.duration,
        centerX: centerX ?? this.centerX,
        centerY: centerY ?? this.centerY,
        size: size ?? this.size,
        id: id,
      );

  Map<String, dynamic> toJson() => {
        'startTimeMicros': startTime.inMicroseconds,
        'durationMicros': duration.inMicroseconds,
        'centerX': centerX,
        'centerY': centerY,
        'size': size,
      };

  factory CameraRegion.fromJson(Map<String, dynamic> json) => CameraRegion(
        startTime:
            Duration(microseconds: (json['startTimeMicros'] as num).toInt()),
        duration:
            Duration(microseconds: (json['durationMicros'] as num).toInt()),
        centerX: (json['centerX'] as num).toDouble(),
        centerY: (json['centerY'] as num).toDouble(),
        size: (json['size'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraRegion &&
          other.startTime == startTime &&
          other.duration == duration &&
          other.centerX == centerX &&
          other.centerY == centerY &&
          other.size == size;

  @override
  int get hashCode =>
      Object.hash(startTime, duration, centerX, centerY, size);
}
