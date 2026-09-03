import 'dart:convert';
import 'dart:io';

import 'native_crash_report.dart';
import 'pii_scrubber.dart';

/// Remembers which reports have already been forwarded, so a rescan (this
/// launch or any later one) never re-sends them.
class NativeCrashWatermarkStore {
  NativeCrashWatermarkStore({required this.path});
  final String path;

  Set<String> _seen = {};
  DateTime? _watermark;
  bool _loaded = false;

  void _load() {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _seen = ((json['seen'] as List?)?.cast<String>() ?? const []).toSet();
      final w = json['watermark']?.toString();
      _watermark = w == null ? null : DateTime.tryParse(w);
    } catch (_) {}
  }

  Set<String> seenFiles() {
    _load();
    return _seen;
  }

  DateTime? watermark() {
    _load();
    return _watermark;
  }

  void record(String fileName, DateTime? at) {
    _load();
    _seen.add(fileName);
    if (at != null && (_watermark == null || at.isAfter(_watermark!))) {
      _watermark = at;
    }
    // Bound the seen-set so it can't grow without limit.
    if (_seen.length > 500) {
      _seen = _seen.toList().sublist(_seen.length - 500).toSet();
    }
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      // Write via a temp file + rename so a crash mid-write can never leave
      // truncated JSON at `path` — that would fail to decode on the next
      // load and silently reset the seen-set, re-forwarding every
      // previously-seen report.
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'seen': _seen.toList(),
          if (_watermark != null)
            'watermark': _watermark!.toUtc().toIso8601String(),
        }),
        flush: true,
      );
      tmp.renameSync(path);
    } catch (_) {
      // Best-effort: persisting the watermark must never break the caller.
    }
  }
}

/// Scans macOS crash reports at startup and forwards the ones caused by our
/// app or a bundled helper via [onCrash]. Best-effort and synchronous; any
/// failure is swallowed so it can never block or crash launch.
class NativeCrashScanner {
  NativeCrashScanner({
    required this.reportsDir,
    required this.watermarkStore,
    required this.scrubber,
    required this.onCrash,
    this.ownProcesses = const {'ffmpeg', 'ffprobe', 'whisper-cli'},
    this.appBundleName = 'Slipreel',
  });

  final Directory reportsDir;
  final NativeCrashWatermarkStore watermarkStore;
  final PiiScrubber scrubber;
  final void Function(NativeCrashReport report) onCrash;
  final Set<String> ownProcesses;
  final String appBundleName;

  void scan() {
    try {
      if (!reportsDir.existsSync()) return;
      final seen = watermarkStore.seenFiles();
      final files = reportsDir
          .listSync()
          .whereType<File>()
          .where((f) {
            final n = _basename(f);
            return (n.endsWith('.ips') || n.endsWith('.crash')) &&
                !seen.contains(n);
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      for (final f in files) {
        final name = _basename(f);
        String contents;
        try {
          contents = f.readAsStringSync();
        } catch (_) {
          continue;
        }
        final report =
            parseCrashReport(contents, fileName: name, scrubber: scrubber);
        if (report == null) {
          // Unparseable: record it so we don't retry every launch.
          watermarkStore.record(name, null);
          continue;
        }
        if (!_isOurs(report, contents)) {
          watermarkStore.record(name, report.crashedAt);
          continue;
        }
        onCrash(report);
        watermarkStore.record(name, report.crashedAt);
      }
    } catch (_) {
      // Best-effort: a scan failure must never block launch.
    }
  }

  bool _isOurs(NativeCrashReport report, String contents) =>
      ownProcesses.contains(report.faultingBinary) ||
      report.faultingBinary == appBundleName ||
      contents.contains('$appBundleName.app');

  String _basename(File f) => f.path.split(Platform.pathSeparator).last;
}
