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
      'mechanism': {'handled': handled, 'type': 'flutter'},
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

  // Best-effort parse of `StackTrace.toString()` lines into frame maps. Frame
  // strings are scrubbed; we keep the raw function text rather than trying to
  // fully parse every Dart stack format.
  List<Map<String, Object?>> _frames(StackTrace? stack) {
    if (stack == null) return const [];
    final lines = stack.toString().trim().split('\n');
    return lines.take(30).map((line) {
      final scrubbed = scrubber.scrub(line.trim());
      return <String, Object?>{
        'function': scrubbed,
        'in_app': !scrubbed.contains('dart:') &&
            !scrubbed.contains('package:flutter/'),
      };
    }).toList();
  }
}
