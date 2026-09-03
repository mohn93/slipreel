import 'dart:convert';

import 'pii_scrubber.dart';

/// One resolved-but-unsymbolicated native frame: the image (binary) it lives in
/// and a hex offset within it. No function name — native reports carry only
/// binary + offset unless a dSYM is applied, which we do not do.
class NativeFrame {
  const NativeFrame({required this.binary, required this.offset});
  final String binary;
  final String offset;
}

/// A minimal, scrubbed view of one macOS crash report (`.ips` or legacy
/// `.crash`). We extract only what we forward; the raw report is never uploaded.
class NativeCrashReport {
  const NativeCrashReport({
    required this.signal,
    required this.faultingBinary,
    required this.frames,
    required this.reportFileName,
    this.osVersion,
    this.appVersion,
    this.crashedAt,
  });

  final String signal;
  final String faultingBinary;
  final List<NativeFrame> frames;
  final String reportFileName;
  final String? osVersion;
  final String? appVersion;
  final DateTime? crashedAt;
}

const int _maxFrames = 15;

/// Parses a crash report into a [NativeCrashReport], or returns null if it does
/// not look like one. Defensive by construction: any parse failure yields null
/// rather than throwing, so a format we cannot read is skipped, never fatal.
/// Every stored string is scrubbed.
NativeCrashReport? parseCrashReport(String contents,
    {required String fileName, required PiiScrubber scrubber}) {
  try {
    final trimmed = contents.trimLeft();
    if (trimmed.startsWith('{')) {
      final r = _parseIps(contents, fileName: fileName, scrubber: scrubber);
      if (r != null) return r;
    }
    return _parseLegacy(contents, fileName: fileName, scrubber: scrubber);
  } catch (_) {
    return null;
  }
}

NativeCrashReport? _parseIps(String contents,
    {required String fileName, required PiiScrubber scrubber}) {
  final lines = const LineSplitter().convert(contents);
  if (lines.isEmpty) return null;
  Map<String, dynamic>? summary;
  try {
    summary = jsonDecode(lines.first) as Map<String, dynamic>;
  } catch (_) {
    summary = null;
  }
  // Body is the rest of the file (everything after the summary line).
  final bodyText =
      lines.length > 1 ? lines.sublist(1).join('\n') : lines.first;
  final Map<String, dynamic> body;
  try {
    body = jsonDecode(bodyText) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }

  final exception = body['exception'];
  final signal = exception is Map
      ? (exception['signal'] ?? exception['type'])?.toString()
      : null;
  final procName = body['procName']?.toString();
  if (signal == null || procName == null) return null;

  final images = (body['usedImages'] as List?) ?? const [];
  String imageName(int i) {
    if (i < 0 || i >= images.length) return 'unknown';
    final img = images[i];
    return (img is Map ? img['name']?.toString() : null) ?? 'unknown';
  }

  final threads = (body['threads'] as List?) ?? const [];
  final triggered = threads.cast<dynamic>().firstWhere(
        (t) => t is Map && t['triggered'] == true,
        orElse: () => null,
      );
  final frames = <NativeFrame>[];
  if (triggered is Map) {
    final raw = (triggered['frames'] as List?) ?? const [];
    for (final f in raw.take(_maxFrames)) {
      if (f is! Map) continue;
      final idx = (f['imageIndex'] as num?)?.toInt() ?? -1;
      final off = (f['imageOffset'] as num?)?.toInt() ?? 0;
      frames.add(NativeFrame(
        binary: scrubber.scrub(imageName(idx)),
        offset: '0x${off.toRadixString(16)}',
      ));
    }
  }

  final os = (summary?['os_version'] ?? _train(body))?.toString();
  final appVersion = summary?['app_version']?.toString();
  final ts = summary?['timestamp']?.toString();

  return NativeCrashReport(
    signal: scrubber.scrub(signal),
    faultingBinary: scrubber.scrub(procName),
    frames: frames,
    reportFileName: fileName,
    osVersion: os == null ? null : scrubber.scrub(os),
    appVersion: appVersion,
    crashedAt: ts == null ? null : DateTime.tryParse(ts.replaceFirst(' ', 'T')),
  );
}

String? _train(Map<String, dynamic> body) {
  final os = body['osVersion'];
  return os is Map ? os['train']?.toString() : null;
}

// Legacy plain-text `.crash`: scan for the labelled lines and the frame table.
final RegExp _procLine = RegExp(r'^Process:\s+(\S+)');
final RegExp _excLine = RegExp(r'^Exception Type:\s+\S+\s*\((SIG\w+)\)');
final RegExp _osLine = RegExp(r'^OS Version:\s+(.+)$');
final RegExp _frameLine =
    RegExp(r'^\s*\d+\s+(\S+)\s+(0x[0-9a-fA-F]+)\s');

NativeCrashReport? _parseLegacy(String contents,
    {required String fileName, required PiiScrubber scrubber}) {
  final lines = const LineSplitter().convert(contents);
  String? proc, signal, os;
  final frames = <NativeFrame>[];
  for (final line in lines) {
    proc ??= _procLine.firstMatch(line)?.group(1);
    signal ??= _excLine.firstMatch(line)?.group(1);
    os ??= _osLine.firstMatch(line)?.group(1);
    final fm = _frameLine.firstMatch(line);
    if (fm != null && frames.length < _maxFrames) {
      frames.add(NativeFrame(
        binary: scrubber.scrub(fm.group(1)!),
        offset: fm.group(2)!,
      ));
    }
  }
  if (proc == null || signal == null) return null;
  return NativeCrashReport(
    signal: scrubber.scrub(signal),
    faultingBinary: scrubber.scrub(proc),
    frames: frames,
    reportFileName: fileName,
    osVersion: os == null ? null : scrubber.scrub(os),
  );
}
