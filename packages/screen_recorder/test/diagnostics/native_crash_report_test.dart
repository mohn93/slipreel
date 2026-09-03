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
  });

  test('scrubs paths out of every parsed field', () {
    final r = parseCrashReport(fixture('ips_sigsegv.ips'),
        fileName: 'ips_sigsegv.ips', scrubber: scrubber)!;
    final blob = '${r.signal} ${r.faultingBinary} '
        '${r.frames.map((f) => '${f.binary} ${f.offset}').join(' ')}';
    expect(blob, isNot(contains('/Users/alice')));
    expect(blob, isNot(contains('alice')));
  });

  test('parses a legacy .crash file', () {
    final r = parseCrashReport(fixture('legacy.crash'),
        fileName: 'legacy.crash', scrubber: scrubber)!;
    expect(r.signal, 'SIGSEGV');
    expect(r.faultingBinary, 'whisper-cli');
    expect(r.frames, isNotEmpty);
  });

  test('returns null for an unparseable file, without throwing', () {
    expect(
        parseCrashReport(fixture('garbage.ips'),
            fileName: 'garbage.ips', scrubber: scrubber),
        isNull);
  });
}
