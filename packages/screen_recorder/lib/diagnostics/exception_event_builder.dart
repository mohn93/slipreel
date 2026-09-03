import '../analytics/analytics_event.dart' show PostHogEvent;
import 'native_crash_report.dart';
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
          'context': _scrubValue(context),
      },
    );
  }

  /// Builds a native `$exception` from a parsed crash report. Marked native by
  /// per-frame `lang: 'native'` and the top-level `exception_platform`; the
  /// `mechanism` keeps v1a's `{handled, synthetic}` shape. Crumbs + activity +
  /// session id come from the crashed session (persisted across the crash).
  PostHogEvent fromNative(
    NativeCrashReport report, {
    List<String> breadcrumbs = const [],
    Map<String, Object?>? activity,
    String? sessionId,
    DateTime? now,
  }) {
    final frames = report.frames
        .map((f) => <String, Object?>{
              'platform': 'custom',
              'lang': 'native',
              'resolved': false,
              'function': f.binary,
              'instruction_addr': '${f.binary}+${f.offset}',
              'in_app': _isBundledBinary(f.binary),
            })
        .toList();
    final item = <String, Object?>{
      'type': report.signal,
      'value': scrubber.scrub('${report.signal} in ${report.faultingBinary}'),
      'mechanism': {'handled': false, 'synthetic': false},
      'stacktrace': {'type': 'raw', 'frames': frames},
    };
    // meta carries the CURRENT launch's session_id, which is wrong here: a
    // native crash belongs to a different (crashed) session. Strip it and set
    // session_id explicitly from the crashed session below, omitting it
    // entirely when unknown (subprocess-crash case) rather than falling back
    // to the scanning launch's own id.
    final nativeMeta = Map<String, Object?>.from(meta)..remove('session_id');
    return PostHogEvent(
      name: r'$exception',
      timestamp: now ?? report.crashedAt ?? DateTime.now(),
      properties: {
        r'$exception_list': [item],
        r'$exception_fingerprint': fingerprintForNative(report),
        'exception_platform': 'native',
        if (report.osVersion != null) 'native_os': report.osVersion,
        ...nativeMeta,
        if (sessionId != null) 'session_id': sessionId,
        'breadcrumbs': breadcrumbs,
        if (activity != null && activity.isNotEmpty)
          'context': _scrubValue(activity),
      },
    );
  }

  String fingerprintForNative(NativeCrashReport report) {
    final top = report.frames.isNotEmpty ? report.frames.first.offset : 'no-frame';
    return '${report.signal}|${report.faultingBinary}|$top';
  }

  static bool _isBundledBinary(String name) =>
      name == 'ffmpeg' || name == 'ffprobe' || name == 'whisper-cli';

  // Recursively scrubs every String inside a context value — nested maps and
  // lists included — so a path can't ride through inside a collection.
  Object? _scrubValue(Object? v) {
    if (v is String) return scrubber.scrub(v);
    if (v is Map) return v.map((k, val) => MapEntry(k, _scrubValue(val)));
    if (v is List) return v.map(_scrubValue).toList();
    return v;
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
