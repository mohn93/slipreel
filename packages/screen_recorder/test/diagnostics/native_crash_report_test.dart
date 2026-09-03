import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/native_crash_report.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  final scrubber = PiiScrubber(homeDir: '/Users/alice');
  String fixture(String name) =>
      File('test/diagnostics/fixtures/$name').readAsStringSync();

  test('parses a modern .ips into signal + binary + frames', () {
    final r = parseCrashReport(fixture('ips_sigsegv.ips'),
        fileName: 'ips_sigsegv.ips', scrubber: scrubber)!;
    expect(r.signal, 'SIGSEGV');
    expect(r.faultingBinary, 'ffmpeg');
    expect(r.frames.first.binary, 'ffmpeg');
    expect(r.frames.first.offset, contains('0x'));
    // Only the triggered thread's frames, capped.
    expect(r.frames.length, 2);
    expect(r.osVersion, contains('15.5'));
    expect(r.reportFileName, 'ips_sigsegv.ips');
    expect(r.appVersion, '1.0.6');
    expect(r.crashedAt, isNotNull);
    final crashedAt = r.crashedAt!.toUtc();
    expect(crashedAt.year, 2026);
    expect(crashedAt.month, 9);
    expect(crashedAt.day, 1);
    expect(crashedAt.hour, 12);
    expect(crashedAt.minute, 0);
    expect(crashedAt.second, 0);
  });

  test('scrubs paths out of every parsed field', () {
    final r = parseCrashReport(fixture('ips_sigsegv.ips'),
        fileName: 'ips_sigsegv.ips', scrubber: scrubber)!;
    // The fixture's second usedImages entry embeds a home path in the image
    // `name` itself (not just procPath, which is never read), so the second
    // triggered-thread frame's `binary` only avoids leaking `/Users/alice`
    // if scrubber.scrub() actually runs when frames are resolved. Deleting
    // that scrub call would leave the raw path in this field and fail here.
    expect(r.frames[1].binary, contains('<path>'));
    expect(r.frames[1].binary, isNot(contains('alice')));
    expect(r.frames[1].binary, isNot(contains('/Users')));
    final blob = '${r.signal} ${r.faultingBinary} ${r.appVersion} '
        '${r.frames.map((f) => '${f.binary} ${f.offset}').join(' ')}';
    expect(blob, isNot(contains('/Users/alice')));
    expect(blob, isNot(contains('alice')));
  });

  test('caps .ips frames at 15 even when the triggered thread has more', () {
    final r = parseCrashReport(fixture('ips_many_frames.ips'),
        fileName: 'ips_many_frames.ips', scrubber: scrubber)!;
    expect(r.frames.length, 15);
  });

  test('parses a legacy .crash file', () {
    final r = parseCrashReport(fixture('legacy.crash'),
        fileName: 'legacy.crash', scrubber: scrubber)!;
    expect(r.signal, 'SIGSEGV');
    expect(r.faultingBinary, 'whisper-cli');
    expect(r.frames, isNotEmpty);
  });

  test('caps legacy .crash frames at 15 even when the thread has more', () {
    final r = parseCrashReport(fixture('legacy_many_frames.crash'),
        fileName: 'legacy_many_frames.crash', scrubber: scrubber)!;
    expect(r.frames.length, 15);
  });

  test('returns null for an unparseable file, without throwing', () {
    expect(
        parseCrashReport(fixture('garbage.ips'),
            fileName: 'garbage.ips', scrubber: scrubber),
        isNull);
  });

  test('responsibleWithinBundle is true when the raw .ips procPath is '
      'inside our bundle', () {
    final r = parseCrashReport(fixture('ips_sigsegv.ips'),
        fileName: 'ips_sigsegv.ips', scrubber: scrubber)!;
    expect(r.responsibleWithinBundle, true);
  });

  test('responsibleWithinBundle is false when the raw .ips procPath is '
      'outside our bundle', () {
    const contents =
        '{"app_name":"Google Chrome","timestamp":"2026-09-01 12:00:00.00 +0000"}\n'
        '{"procName":"Google Chrome",'
        '"procPath":"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",'
        '"exception":{"signal":"SIGSEGV"},'
        '"usedImages":[{"index":0,"name":"Google Chrome"}],'
        '"threads":[{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":1}]}]}';
    final r = parseCrashReport(contents,
        fileName: 'foreign.ips', scrubber: scrubber)!;
    expect(r.responsibleWithinBundle, false);
  });

  test('responsibleWithinBundle is true for the legacy fixture\'s in-bundle '
      'Path: line', () {
    final r = parseCrashReport(fixture('legacy.crash'),
        fileName: 'legacy.crash', scrubber: scrubber)!;
    expect(r.responsibleWithinBundle, true);
  });

  test('responsibleWithinBundle is false when the legacy Path: line is '
      'outside our bundle', () {
    const contents = 'Process:               Google Chrome [123]\n'
        'Path:                  /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n'
        'OS Version:            macOS 13.2 (22D49)\n'
        'Exception Type:        EXC_BAD_ACCESS (SIGSEGV)\n'
        'Thread 0 Crashed:\n'
        '0   Google Chrome 0x0000000100000000 0x100000000 + 0\n';
    final r = parseCrashReport(contents,
        fileName: 'foreign.crash', scrubber: scrubber)!;
    expect(r.responsibleWithinBundle, false);
  });
}
