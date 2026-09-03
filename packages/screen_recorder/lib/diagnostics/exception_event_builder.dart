import '../analytics/analytics_event.dart' show PostHogEvent;
import 'pii_scrubber.dart';

/// Turns a Dart error + stack into a PostHog `$exception` event. Pure and
/// deterministic: scrubbing, frame parsing, and fingerprinting all happen here
/// so they can be unit-tested without any network or service.
class ExceptionEventBuilder {
  ExceptionEventBuilder({required this.scrubber, required this.meta});

  final PiiScrubber scrubber;
  final Map<String, Object?> meta;

  PostHogEvent fromDart(
    Object error,
    StackTrace? stack, {
    required bool handled,
    List<String> breadcrumbs = const [],
    Map<String, Object?>? context,
    String? messageOverride,
    DateTime? now,
  }) {
    final frames = _frames(stack);
    final item = <String, Object?>{
      'type': error.runtimeType.toString(),
      'value': scrubber.scrub(messageOverride ?? error.toString()),
      // PostHog's mechanism is {handled, synthetic}; there is no `type` field.
      'mechanism': {'handled': handled, 'synthetic': false},
      'stacktrace': {'type': 'raw', 'frames': frames},
    };
    return PostHogEvent(
      name: r'$exception',
      timestamp: now ?? DateTime.now(),
      properties: {
        r'$exception_list': [item],
        r'$exception_fingerprint': fingerprintFor(error, stack),
        ...meta,
        'breadcrumbs': breadcrumbs,
        if (context != null && context.isNotEmpty)
          'context': context.map(
              (k, v) => MapEntry(k, v is String ? scrubber.scrub(v) : v)),
      },
    );
  }

  String fingerprintFor(Object error, StackTrace? stack) {
    final top = _frames(stack).isNotEmpty
        ? (_frames(stack).first['function'] ?? _frames(stack).first['filename'])
        : 'no-frame';
    return '${error.runtimeType}|$top';
  }

  // Matches a Dart VM frame line, e.g.
  //   #0      Foo.bar.<anonymous closure> (package:app/x.dart:12:3)
  // Group 1 is the member (function); group 2 is the location.
  static final RegExp _vmFrame = RegExp(r'^#\d+\s+(.+?)\s+\((.+)\)$');
  // Peels a trailing `:line` or `:line:col` off a location (the leading part is
  // a `package:`/`dart:` URI that also contains colons, so peel from the right).
  static final RegExp _locTail = RegExp(r':(\d+)(?::(\d+))?$');

  List<Map<String, Object?>> _frames(StackTrace? stack) {
    if (stack == null) return const [];
    return stack
        .toString()
        .trim()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .take(30)
        .map((line) => _parseFrame(scrubber.scrub(line.trim())))
        .toList();
  }

  // Best-effort parse of one scrubbed `StackTrace` line into a PostHog frame.
  // PostHog requires `platform` + `lang` on every frame; `custom` marks a
  // client-sent, pre-resolved frame (no server symbolication). VM frames are
  // split into function/filename/lineno/colno; anything else (async gaps, AOT
  // address frames, a redacted line) keeps the whole line as `function`.
  Map<String, Object?> _parseFrame(String scrubbed) {
    final frame = <String, Object?>{
      'platform': 'custom',
      'lang': 'dart',
      'resolved': true,
    };
    final m = _vmFrame.firstMatch(scrubbed);
    if (m == null) {
      frame['function'] = scrubbed;
      frame['in_app'] = !scrubbed.contains('dart:') &&
          !scrubbed.contains('package:flutter/');
      return frame;
    }
    frame['function'] = m.group(1);
    var loc = m.group(2)!;
    final tail = _locTail.firstMatch(loc);
    if (tail != null) {
      frame['lineno'] = int.parse(tail.group(1)!);
      if (tail.group(2) != null) frame['colno'] = int.parse(tail.group(2)!);
      loc = loc.substring(0, tail.start);
    }
    frame['filename'] = loc;
    frame['in_app'] =
        !loc.startsWith('dart:') && !loc.startsWith('package:flutter/');
    return frame;
  }
}
