import 'dart:convert';
import 'dart:io';

import 'native_crash_report.dart';
import 'pii_scrubber.dart';

/// Remembers which reports have already been processed, so a rescan (this
/// launch or any later one) never re-sends them.
///
/// Two sets, deliberately: forwarded ("ours") names are effectively permanent —
/// evicting one would re-forward a real crash — while skipped names (foreign,
/// unparseable, or deferred over-cap reports) are freely evictable, since
/// re-skipping one later is harmless. A single shared, evictable set (v1's
/// design) let a big foreign-crash backlog push an ours name out and cause a
/// duplicate upload.
class NativeCrashWatermarkStore {
  NativeCrashWatermarkStore({required this.path});
  final String path;

  // Kept high but not unbounded: forwarded names are the ones we must never
  // lose, so this cap is a last-resort guard, an order of magnitude above the
  // skipped cap.
  static const int _maxForwarded = 5000;
  static const int _maxSkipped = 500;

  Set<String> _forwarded = {};
  Set<String> _skipped = {};
  DateTime? _watermark;
  bool _loaded = false;

  void _load() {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _forwarded =
          ((json['seen'] as List?)?.cast<String>() ?? const []).toSet();
      // Backward-compat: files written before the split have no `skipped` key.
      _skipped =
          ((json['skipped'] as List?)?.cast<String>() ?? const []).toSet();
      final w = json['watermark']?.toString();
      _watermark = w == null ? null : DateTime.tryParse(w);
    } catch (_) {}
  }

  /// Every already-processed report name (forwarded OR skipped). The scanner
  /// skips a file present in either set.
  Set<String> seenFiles() {
    _load();
    return {..._forwarded, ..._skipped};
  }

  DateTime? watermark() {
    _load();
    return _watermark;
  }

  /// Records a processed report. [forwarded] true means it was an ours crash we
  /// sent (kept effectively forever); false means it was skipped (foreign,
  /// unparseable, or deferred) and may be evicted freely.
  void record(String fileName, DateTime? at, {required bool forwarded}) {
    _load();
    if (forwarded) {
      _forwarded.add(fileName);
      if (_forwarded.length > _maxForwarded) {
        _forwarded = _forwarded
            .toList()
            .sublist(_forwarded.length - _maxForwarded)
            .toSet();
      }
    } else {
      _skipped.add(fileName);
      if (_skipped.length > _maxSkipped) {
        _skipped =
            _skipped.toList().sublist(_skipped.length - _maxSkipped).toSet();
      }
    }
    if (at != null && (_watermark == null || at.isAfter(_watermark!))) {
      _watermark = at;
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
          'seen': _forwarded.toList(),
          'skipped': _skipped.toList(),
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
    this.appBundleName = kAppBundleName,
    this.maxReportsPerScan = 50,
    this.maxReportBytes = 4 * 1024 * 1024,
  });

  final Directory reportsDir;
  final NativeCrashWatermarkStore watermarkStore;
  final PiiScrubber scrubber;
  final void Function(NativeCrashReport report) onCrash;
  final Set<String> ownProcesses;
  final String appBundleName;

  /// Upper bound on reports parsed/forwarded per scan. Bounds UI-thread work
  /// and prevents a first-launch backlog flood; the newest reports win and the
  /// rest are recorded as seen (deferred) without parsing.
  final int maxReportsPerScan;

  /// Reports larger than this are recorded as seen without being read into the
  /// parser — a crash report this big is not one of ours worth uploading.
  final int maxReportBytes;

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
        // Newest first: a first-launch backlog forwards the most recent
        // reports and defers the rest, rather than being dominated by weeks of
        // stale ones.
        ..sort((a, b) => _mtimeOf(b).compareTo(_mtimeOf(a)));

      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        final name = _basename(f);
        // Beyond the per-scan cap: record as seen (skipped) WITHOUT parsing, so
        // a large backlog neither floods this launch nor forces a re-scan of
        // the same files every launch.
        if (i >= maxReportsPerScan) {
          watermarkStore.record(name, null, forwarded: false);
          continue;
        }
        // Oversized: don't read a huge file into the parser. Record + skip.
        int size;
        try {
          size = f.lengthSync();
        } catch (_) {
          // Transient stat failure: leave it for a later scan.
          continue;
        }
        if (size > maxReportBytes) {
          watermarkStore.record(name, null, forwarded: false);
          continue;
        }
        String contents;
        try {
          contents = f.readAsStringSync();
        } catch (_) {
          continue;
        }
        final report = parseCrashReport(contents,
            fileName: name, scrubber: scrubber, appBundleName: appBundleName);
        if (report == null) {
          // Unparseable: record it so we don't retry every launch.
          watermarkStore.record(name, null, forwarded: false);
          continue;
        }
        if (!_isOurs(report)) {
          watermarkStore.record(name, report.crashedAt, forwarded: false);
          continue;
        }
        onCrash(report);
        watermarkStore.record(name, report.crashedAt, forwarded: true);
      }
    } catch (_) {
      // Best-effort: a scan failure must never block launch.
    }
  }

  DateTime _mtimeOf(File f) {
    try {
      return f.lastModifiedSync();
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  bool _isOurs(NativeCrashReport report) =>
      ownProcesses.contains(report.faultingBinary) ||
      report.faultingBinary == appBundleName ||
      report.responsibleWithinBundle;

  String _basename(File f) => f.path.split(Platform.pathSeparator).last;
}
