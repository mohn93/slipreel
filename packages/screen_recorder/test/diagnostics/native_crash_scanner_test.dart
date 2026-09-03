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

  NativeCrashScanner make(List<NativeCrashReport> out) => NativeCrashScanner(
        reportsDir: reports,
        watermarkStore:
            NativeCrashWatermarkStore(path: '${state.path}/wm.json'),
        scrubber: scrubber,
        onCrash: out.add,
      );

  void writeReport(String name, String procName) {
    File('${reports.path}/$name').writeAsStringSync(
      '{"app_name":"Slipreel","timestamp":"2026-09-01 12:00:00.00 +0000","os_version":"macOS 15.5"}\n'
      '{"procName":"$procName","exception":{"signal":"SIGSEGV"},'
      '"usedImages":[{"index":0,"name":"$procName"}],'
      '"threads":[{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":10}]}]}',
    );
  }

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

  test('a garbage file is skipped without throwing', () {
    File('${reports.path}/bad.ips').writeAsStringSync('not a report');
    final out = <NativeCrashReport>[];
    expect(() => make(out).scan(), returnsNormally);
    expect(out, isEmpty);
  });
}
