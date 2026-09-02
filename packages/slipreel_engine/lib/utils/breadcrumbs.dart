import 'dart:collection';

import 'package:logger/logger.dart';

/// A small in-memory ring buffer of recent log lines, attached to exception and
/// feedback reports for context. Bounded so it can't grow; messages are capped
/// at insert. Not scrubbed here — the PiiScrubber runs at attach time.
class Breadcrumbs {
  Breadcrumbs({this.capacity = 40, this.maxMessageLength = 200});

  static final Breadcrumbs instance = Breadcrumbs();

  final int capacity;
  final int maxMessageLength;
  final Queue<String> _entries = Queue<String>();

  void add({
    required String zone,
    required String level,
    required String message,
    DateTime? time,
  }) {
    // Best-effort: breadcrumb capture must never throw and break the app.
    try {
      final msg = message.length > maxMessageLength
          ? message.substring(0, maxMessageLength)
          : message;
      _entries.addLast('[$zone] $level $msg');
      while (_entries.length > capacity) {
        _entries.removeFirst();
      }
    } catch (_) {
      // Swallow — logging a breadcrumb must never break the app.
    }
  }

  List<String> snapshot() => _entries.toList(growable: false);

  void clear() => _entries.clear();
}

/// A `logger` output that mirrors each line into [Breadcrumbs.instance]. Added
/// alongside the console output so app logging is otherwise unchanged.
class BreadcrumbLogOutput extends LogOutput {
  BreadcrumbLogOutput(this.zoneName);
  final String zoneName;

  @override
  void output(OutputEvent event) {
    // Best-effort: a malformed log event must never break app logging.
    try {
      Breadcrumbs.instance.add(
        zone: zoneName,
        level: event.origin.level.name.toUpperCase(),
        message: event.origin.message.toString(),
        time: event.origin.time,
      );
    } catch (_) {
      // Swallow — logging a breadcrumb must never break the app.
    }
  }
}
