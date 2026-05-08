import 'cursor_state.dart';

/// Represents cursor position at a specific time, plus the system
/// cursor's visual state (arrow, I-beam, hand, etc.) at that moment.
class CursorPosition {
  final double x;
  final double y;
  final int timestampMicros;
  final bool isClicked;

  /// What the OS pointer looked like at this sample. The native
  /// recorder samples NSCursor.currentSystem and matches against the
  /// stock cursor list; unrecognised cursors default to [CursorState.arrow].
  /// Legacy recordings that pre-date this field also load as arrow.
  final CursorState state;

  const CursorPosition({
    required this.x,
    required this.y,
    required this.timestampMicros,
    this.isClicked = false,
    this.state = CursorState.arrow,
  });

  Map<String, dynamic> toJson() {
    return {
      'x': x,
      'y': y,
      'timestampMicros': timestampMicros,
      'isClicked': isClicked,
      'state': state.wireName,
    };
  }

  factory CursorPosition.fromJson(Map<String, dynamic> json) {
    return CursorPosition(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      timestampMicros: json['timestampMicros'] as int,
      isClicked: json['isClicked'] as bool? ?? false,
      state: CursorStateWire.fromWireName(json['state'] as String?),
    );
  }

  @override
  String toString() {
    return 'CursorPosition(x: $x, y: $y, timestamp: $timestampMicros, '
        'clicked: $isClicked, state: ${state.wireName})';
  }
}
