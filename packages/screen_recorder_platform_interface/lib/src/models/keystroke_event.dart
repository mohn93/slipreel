/// How a captured keystroke should be treated for overlay/timeline display.
///
/// Derived purely from [KeystrokeEvent.label], which already encodes the
/// active modifiers as glyphs (⌃⌥⇧⌘) followed by the key. Keeping the
/// classification on the label means it works on previously-recorded
/// sidecar files without any schema change or native rebuild.
enum KeystrokeKind {
  /// Plain text entry — a printable character with no command-class
  /// modifier (e.g. "A", "5", ";", or ⇧+letter for a capital). This is
  /// what the user is *writing*, so it is never shown.
  typing,

  /// A single navigation/action key with no command-class modifier
  /// (Space, ↩, ⎋, ⇥, ⌫, arrows, F-keys, …). Shown only when the user
  /// opts into single-key shortcuts.
  singleKey,

  /// A real shortcut: any key combined with ⌘, ⌃, or ⌥ (2+ keys).
  /// Always shown while the overlay is enabled.
  shortcut,
}

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

  // Command-class modifier glyphs. The presence of any of these makes the
  // press a real shortcut (⇧ alone does not — ⇧+letter is just a capital).
  static const String _command = '⌘'; // ⌘
  static const String _control = '⌃'; // ⌃
  static const String _option = '⌥'; // ⌥
  static const String _shift = '⇧'; // ⇧

  // Single keys that count as navigation/action shortcuts (never typing).
  static const Set<String> _specialKeys = {
    '↩', // ↩ return
    '⌤', // ⌤ enter (numpad)
    '⎋', // ⎋ escape
    '⌫', // ⌫ delete (backspace)
    '⌦', // ⌦ forward delete
    '⇥', // ⇥ tab
    'Space',
    '←', '→', '↓', '↑', // ← → ↓ ↑
    '⇞', '⇟', // ⇞ ⇟ page up/down
    '↖', '↘', // ↖ ↘ home/end
  };

  /// Classifies this event for overlay/timeline display filtering.
  KeystrokeKind get kind {
    if (label.isEmpty) return KeystrokeKind.typing;
    // Any command-class modifier ⇒ a real shortcut, regardless of the key.
    if (label.contains(_command) ||
        label.contains(_control) ||
        label.contains(_option)) {
      return KeystrokeKind.shortcut;
    }
    // No command modifier: strip a leading ⇧ to expose the base key.
    final base = label.startsWith(_shift) ? label.substring(1) : label;
    return _isSpecialKey(base) ? KeystrokeKind.singleKey : KeystrokeKind.typing;
  }

  static bool _isSpecialKey(String base) {
    if (_specialKeys.contains(base)) return true;
    // Function keys F1–F12.
    if (base.length >= 2 && base[0] == 'F') {
      final n = int.tryParse(base.substring(1));
      return n != null && n >= 1 && n <= 12;
    }
    return false;
  }

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
