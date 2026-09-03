import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/native_crash_report.dart';
import 'package:screen_recorder/diagnostics/native_crash_scanner.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  late Directory reports;
  late Directory state;
  final scrubber = PiiScrubber(homeDir: '/Users/alice');

  setUp(() {
    reports = Directory.systemTemp.createTempSync('reports');
    state = Directory.systemTemp.createTempSync('state');
  });
  tearDown(() {
    reports.deleteSync(recursive: true);
    state.deleteSync(recursive: true);
  });

  NativeCrashScanner make(List<NativeCrashReport> out,
          {int maxReportsPerScan = 50}) =>
      NativeCrashScanner(
        reportsDir: reports,
        watermarkStore:
            NativeCrashWatermarkStore(path: '${state.path}/wm.json'),
        scrubber: scrubber,
        onCrash: out.add,
        maxReportsPerScan: maxReportsPerScan,
      );

  void writeReport(String name, String procName) {
    File('${reports.path}/$name').writeAsStringSync(
      '{"app_name":"Slipreel","timestamp":"2026-09-01 12:00:00.00 +0000","os_version":"macOS 15.5"}\n'
      '{"procName":"$procName","exception":{"signal":"SIGSEGV"},'
      '"usedImages":[{"index":0,"name":"$procName"}],'
      '"threads":[{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":10}]}]}',
    );
  }

  // I3: only the newest maxReportsPerScan reports are forwarded; the rest are
  // recorded as seen (deferred) so a later scan re-processes nothing.
  test('caps work per scan to the newest N, deferring the rest', () {
    // Four ours reports with distinct, increasing mtimes.
    final base = DateTime(2026, 9, 1, 12);
    for (var i = 0; i < 4; i++) {
      final name = 'ours$i.ips';
      writeReport(name, 'ffmpeg');
      File('${reports.path}/$name')
          .setLastModifiedSync(base.add(Duration(minutes: i)));
    }
    final out = <NativeCrashReport>[];
    make(out, maxReportsPerScan: 2).scan();
    // Only the two newest (ours3, ours2) are forwarded.
    expect(out.length, 2);
    expect(out.map((r) => r.reportFileName).toSet(), {'ours3.ips', 'ours2.ips'});

    // A second scan (fresh scanner, same watermark) forwards nothing: the
    // newest two are forwarded-seen and the older two are skipped-seen.
    final out2 = <NativeCrashReport>[];
    make(out2, maxReportsPerScan: 2).scan();
    expect(out2, isEmpty);
  });

  // I7: a forwarded ("ours") name is never evicted, even when many skipped
  // names pile up past the skipped cap.
  test('a forwarded name survives eviction pressure from many skipped names',
      () {
    final wm = NativeCrashWatermarkStore(path: '${state.path}/wm.json');
    wm.record('ours-real-crash.ips', DateTime(2026, 9, 1), forwarded: true);
    // Push far past the skipped cap (500) with foreign names.
    for (var i = 0; i < 700; i++) {
      wm.record('foreign$i.ips', null, forwarded: false);
    }
    // Fresh store reading the same file: the forwarded name is still present.
    final reloaded = NativeCrashWatermarkStore(path: '${state.path}/wm.json');
    expect(reloaded.seenFiles(), contains('ours-real-crash.ips'));
  });

  // T4: garbage wm.json must degrade to empty/null, never throw.
  test('a garbage watermark file degrades to empty without throwing', () {
    File('${state.path}/wm.json').writeAsStringSync('not json at all {{{');
    final wm = NativeCrashWatermarkStore(path: '${state.path}/wm.json');
    expect(() => wm.seenFiles(), returnsNormally);
    expect(wm.seenFiles(), isEmpty);
    expect(wm.watermark(), isNull);
  });

  test('forwards only our processes', () {
    writeReport('ours.ips', 'ffmpeg');
    writeReport('other.ips', 'Google Chrome');
    final out = <NativeCrashReport>[];
    make(out).scan();
    expect(out.map((r) => r.faultingBinary), ['ffmpeg']);
  });

  test('is idempotent: a second scan forwards nothing new', () {
    writeReport('ours.ips', 'whisper-cli');
    final out = <NativeCrashReport>[];
    final scanner = make(out);
    scanner.scan();
    scanner.scan();
    expect(out.length, 1);
  });

  test('a fresh scanner (new run) skips already-watermarked files', () {
    writeReport('ours.ips', 'ffmpeg');
    final out = <NativeCrashReport>[];
    make(out).scan(); // records watermark
    final out2 = <NativeCrashReport>[];
    make(out2).scan(); // new scanner, same watermark file
    expect(out2, isEmpty);
  });

  test(
      'a non-ours report is recorded in the watermark but never forwarded',
      () {
    writeReport('other.ips', 'Google Chrome');
    final out = <NativeCrashReport>[];
    make(out).scan();
    expect(out, isEmpty);

    // A second scan (fresh scanner, same watermark file) must not re-process
    // it either — proving it was recorded in the seen-set, not just skipped
    // by the ownProcesses filter on this one pass.
    final out2 = <NativeCrashReport>[];
    make(out2).scan();
    expect(out2, isEmpty);
  });

  test('a garbage file is skipped without throwing', () {
    File('${reports.path}/bad.ips').writeAsStringSync('not a report');
    final out = <NativeCrashReport>[];
    expect(() => make(out).scan(), returnsNormally);
    expect(out, isEmpty);
  });

  test('forwards an in-process crash whose responsible process is our app',
      () {
    // Shaped like a real in-process crash: procName is the app executable,
    // procPath sits inside the bundle.
    File('${reports.path}/inproc.ips').writeAsStringSync(
      '{"app_name":"Slipreel","timestamp":"2026-09-01 12:00:00.00 +0000",'
      '"os_version":"macOS 15.5"}\n'
      '{"procName":"Slipreel",'
      '"procPath":"/Users/alice/Applications/Slipreel.app/Contents/MacOS/Slipreel",'
      '"exception":{"signal":"SIGSEGV"},'
      '"usedImages":[{"index":0,"name":"Slipreel"}],'
      '"threads":[{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":10}]}]}',
    );
    final out = <NativeCrashReport>[];
    make(out).scan();
    expect(out.map((r) => r.faultingBinary), ['Slipreel']);
  });

  test(
      'does not forward a foreign process crash that merely references our '
      'bundle in its file contents', () {
    // The responsible process (Google Chrome) is NOT ours, but one of the
    // report's images/frames happens to reference our bundle path — a
    // whole-file substring match would wrongly treat this as ours.
    File('${reports.path}/foreign.ips').writeAsStringSync(
      '{"app_name":"Google Chrome","timestamp":"2026-09-01 12:00:00.00 +0000",'
      '"os_version":"macOS 15.5"}\n'
      '{"procName":"Google Chrome",'
      '"procPath":"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",'
      '"exception":{"signal":"SIGSEGV"},'
      '"usedImages":[{"index":0,"name":"Google Chrome"},'
      '{"index":1,"name":"/Users/alice/Applications/Slipreel.app/Contents/Frameworks/SomeFramework.framework/SomeFramework"}],'
      '"threads":[{"triggered":true,"frames":[{"imageIndex":1,"imageOffset":10}]}]}',
    );
    final out = <NativeCrashReport>[];
    make(out).scan();
    expect(out, isEmpty);
  });
}
