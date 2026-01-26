/// Represents cursor position at a specific time
class CursorPosition {
  final double x;
  final double y;
  final int timestampMicros;
  final bool isClicked;

  const CursorPosition({
    required this.x,
    required this.y,
    required this.timestampMicros,
    this.isClicked = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'x': x,
      'y': y,
      'timestampMicros': timestampMicros,
      'isClicked': isClicked,
    };
  }

  factory CursorPosition.fromJson(Map<String, dynamic> json) {
    return CursorPosition(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      timestampMicros: json['timestampMicros'] as int,
      isClicked: json['isClicked'] as bool? ?? false,
    );
  }

  @override
  String toString() {
    return 'CursorPosition(x: $x, y: $y, timestamp: $timestampMicros, clicked: $isClicked)';
  }
}
