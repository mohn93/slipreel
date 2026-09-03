import 'dart:collection';

/// A bounded in-memory ring of recent product events, attached to exception
/// and feedback reports for context. Bounded so it can't grow; messages are
/// capped at insert. Not scrubbed here — the PiiScrubber runs at attach time.
class Breadcrumbs {
  Breadcrumbs({this.capacity = 40, this.maxMessageLength = 200});

  static final Breadcrumbs instance = Breadcrumbs();

  final int capacity;
  final int maxMessageLength;
  final Queue<String> _entries = Queue<String>();

  /// Records a recent product event (e.g. `recording_started`, `export_failed`)
  /// as a breadcrumb. Non-identifying by construction — pass only the same cheap
  /// props used for analytics. Best-effort; never throws.
  void dropEvent(String name, {Map<String, Object?>? props}) {
    try {
      final p = (props == null || props.isEmpty)
          ? ''
          : ' ${props.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
      var msg = 'event:$name$p';
      if (msg.length > maxMessageLength) msg = msg.substring(0, maxMessageLength);
      _entries.addLast(msg);
      while (_entries.length > capacity) {
        _entries.removeFirst();
      }
    } catch (_) {
      // Swallow — recording a breadcrumb must never break the app.
    }
  }

  List<String> snapshot() => _entries.toList(growable: false);

  void clear() => _entries.clear();
}
