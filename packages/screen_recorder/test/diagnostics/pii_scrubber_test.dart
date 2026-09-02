import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  final s = PiiScrubber(homeDir: '/Users/alice', maxStringLength: 500);

  group('home dir', () {
    test('collapses a bare home dir to ~', () {
      expect(s.scrub('/Users/alice'), '~');
    });

    test('collapses every bare occurrence', () {
      expect(s.scrub('a /Users/alice b /Users/alice c'), 'a ~ b ~ c');
    });
  });

  group('path redaction', () {
    test('redacts a home-relative file path (filename gone)', () {
      final out = s.scrub('/Users/alice/Movies/clip.mp4');
      expect(out, '<path>');
      expect(out, isNot(contains('Movies')));
      expect(out, isNot(contains('clip.mp4')));
    });

    test('redacts a filename containing spaces (home-relative)', () {
      final out = s.scrub('/Users/alice/Movies/Client Call.mov');
      expect(out, isNot(contains('Client')));
      expect(out, isNot(contains('Call.mov')));
      expect(out, contains('<path>'));
    });

    test('redacts a path outside the home dir', () {
      final out = s.scrub('/Volumes/EXT/clip.mov');
      expect(out, isNot(contains('EXT')));
      expect(out, isNot(contains('clip.mov')));
    });

    test("redacts another user's home dir", () {
      final out = s.scrub('/Users/bob/secret/plan.txt');
      expect(out, isNot(contains('bob')));
      expect(out, isNot(contains('plan.txt')));
    });

    test('redacts a quoted path with spaces, keeping the message around it', () {
      final out = s.scrub(
          "FileSystemException: Cannot open, path = '/Volumes/EXT/My Clip.mov' (OS Error: No such file, errno = 2)");
      expect(out, isNot(contains('Volumes')));
      expect(out, isNot(contains('My Clip.mov')));
      // Non-path context survives.
      expect(out, contains('FileSystemException'));
      expect(out, contains('errno = 2'));
    });

    test('redacts a no-extension directory path', () {
      final out = s.scrub('/Volumes/EXT/exports');
      expect(out, isNot(contains('EXT')));
      expect(out, isNot(contains('exports')));
    });

    test('redacts multiple paths on one line', () {
      final out = s.scrub('-i /Users/alice/in.mov -o /Users/alice/out file.mp4');
      expect(out, isNot(contains('in.mov')));
      expect(out, isNot(contains('out file.mp4')));
    });

    test('redacts a spaced filename with a LONG extension', () {
      // e.g. .screenflow (10), .photoslibrary (13) — beyond the old {1,6} cap.
      final out = s.scrub('/Users/bob/My Recording.screenflow failed');
      expect(out, isNot(contains('Recording.screenflow')));
      expect(out, isNot(contains('bob')));
      expect(out, contains('failed'));
    });

    test('redacts a spaced path trailed by a colon (not whitespace)', () {
      final out = s.scrub("path = '/Volumes/EXT/My Clip.mov': No such file");
      expect(out, isNot(contains('My Clip.mov')));
      expect(out, isNot(contains('EXT')));
      expect(out, contains('No such file'));
    });

    test('redacts an unquoted spaced path trailed by a colon', () {
      final out = s.scrub('/Volumes/EXT/My Clip.mov: No such file');
      expect(out, isNot(contains('My Clip.mov')));
      expect(out, contains('No such file'));
    });
  });

  group('ReDoS / large input', () {
    test('caps input before the regex passes (no super-linear stall)', () {
      final sw = Stopwatch()..start();
      final out = s.scrub('/x ' * 40000); // 120KB of path-like tokens
      sw.stop();
      expect(out.length, lessThanOrEqualTo(500));
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });
  });

  group('documented residual (spaced basename, no extension)', () {
    // Regex cannot distinguish this from a path followed by prose without
    // destroying error context. The username is still redacted; only a
    // space-containing folder/basename word after the redaction survives.
    // Pinned so a future change to the residual is a deliberate, visible edit.
    test('leaves the post-space fragment of a spaced no-extension path', () {
      final out = s.scrub('/Volumes/John Smith/clip');
      expect(out, isNot(contains('/Volumes')));
      expect(out, isNot(contains('John')));
      expect(out, contains('Smith/clip')); // known residual
    });
  });

  group('does NOT over-redact non-paths', () {
    test('leaves prose untouched', () {
      expect(s.scrub('nothing private here'), 'nothing private here');
    });

    test('leaves a bare filename in prose (no directory) untouched', () {
      expect(s.scrub('see report.txt for details'), 'see report.txt for details');
    });

    test('leaves an apostrophe in prose untouched', () {
      final out = s.scrub("it's fine");
      expect(out, "it's fine");
    });

    test('leaves a Dart stack frame package: URI intact', () {
      const frame =
          '#0      Foo.bar (package:screen_recorder/src/foo.dart:12:3)';
      final out = s.scrub(frame);
      expect(out, contains('package:screen_recorder'));
      expect(out, contains('foo.dart'));
    });

    test('leaves a mid-word slash expression untouched', () {
      expect(s.scrub('choose and/or maybe'), 'choose and/or maybe');
    });
  });

  group('length + list', () {
    test('applies the length cap after redaction', () {
      final tiny = PiiScrubber(homeDir: '/Users/alice', maxStringLength: 4);
      expect(tiny.scrub('x' * 100).length, 4);
    });

    test('scrubAll caps list size, keeping the most recent (last) items', () {
      final out = s.scrubAll(['a', 'b', 'c', 'd'], maxItems: 2);
      expect(out, ['c', 'd']);
    });

    test('scrubAll redacts each entry', () {
      final out = s.scrubAll(['/Users/alice/x.mov', 'plain']);
      expect(out[0], isNot(contains('x.mov')));
      expect(out[1], 'plain');
    });
  });
}
