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
}
