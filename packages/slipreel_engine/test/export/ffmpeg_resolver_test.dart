import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

void main() {
  group('FfmpegResolver', () {
    test('prefers the bundled path when it exists', () {
      final r = FfmpegResolver(
        bundledPath: '/app/bundled/ffmpeg',
        fileExists: (p) => p == '/app/bundled/ffmpeg',
        pathEnv: '/usr/bin',
      );
      expect(r.resolve(), '/app/bundled/ffmpeg');
    });

    test('falls through to Homebrew when no bundled path', () {
      final r = FfmpegResolver(
        fileExists: (p) => p == '/opt/homebrew/bin/ffmpeg',
        pathEnv: '/usr/bin',
      );
      expect(r.resolve(), '/opt/homebrew/bin/ffmpeg');
    });

    test('falls through to /usr/local/bin', () {
      final r = FfmpegResolver(
        fileExists: (p) => p == '/usr/local/bin/ffmpeg',
        pathEnv: '',
      );
      expect(r.resolve(), '/usr/local/bin/ffmpeg');
    });

    test('falls through to a PATH entry', () {
      final r = FfmpegResolver(
        fileExists: (p) => p == '/custom/bin/ffmpeg',
        pathEnv: '/nope:/custom/bin',
      );
      expect(r.resolve(), '/custom/bin/ffmpeg');
    });

    test('throws FfmpegNotFoundException listing searched locations', () {
      final r = FfmpegResolver(
        fileExists: (_) => false,
        pathEnv: '/usr/bin',
      );
      expect(
        () => r.resolve(),
        throwsA(isA<FfmpegNotFoundException>().having(
          (e) => e.searchedLocations,
          'searchedLocations',
          contains('/opt/homebrew/bin/ffmpeg'),
        )),
      );
    });

    test('caches the first successful resolution', () {
      var calls = 0;
      final r = FfmpegResolver(
        fileExists: (p) {
          calls++;
          return p == '/opt/homebrew/bin/ffmpeg';
        },
        pathEnv: '',
      );
      r.resolve();
      final callsAfterFirst = calls;
      r.resolve();
      expect(calls, callsAfterFirst, reason: 'second resolve must use cache');
    });
  });
}
