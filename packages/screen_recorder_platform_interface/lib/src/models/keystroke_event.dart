/// A single keyboard event captured during screen recording.
class KeystrokeEvent {
  final int timestampMicros;

  /// Human-readable display label, e.g. "⌘C", "⇧⌘Z", "Space", "↩".
  /// Composed on the native side from the key code + active modifiers.
  final String label;

  const KeystrokeEvent({
    required this.timestampMicros,
    required this.label,
  });

  Map<String, dynamic> toJson() => {
    'timestampMicros': timestampMicros,
    'label': label,
  };

  factory KeystrokeEvent.fromJson(Map<String, dynamic> json) => KeystrokeEvent(
    timestampMicros: json['timestampMicros'] as int,
    label: json['label'] as String? ?? '',
  );

  @override
  String toString() =>
      'KeystrokeEvent(t=$timestampMicros µs, label="$label")';
}
