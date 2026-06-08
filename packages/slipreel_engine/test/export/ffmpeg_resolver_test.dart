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

  group('resolveProbe', () {
    test('derives the sibling ffprobe from the resolved ffmpeg path', () {
      final r = FfmpegResolver(
        fileExists: (p) => p == '/opt/homebrew/bin/ffmpeg',
        pathEnv: '',
      );
      expect(r.resolveProbe(), '/opt/homebrew/bin/ffprobe');
    });

    test('derives ffprobe from a bundled ffmpeg path', () {
      final r = FfmpegResolver(
        bundledPath: '/app/bundled/ffmpeg',
        fileExists: (p) => p == '/app/bundled/ffmpeg',
        pathEnv: '',
      );
      expect(r.resolveProbe(), '/app/bundled/ffprobe');
    });

    test('preserves a .exe suffix when deriving ffprobe', () {
      final r = FfmpegResolver(
        bundledPath: r'C:\app\ffmpeg.exe',
        fileExists: (p) => p == r'C:\app\ffmpeg.exe',
        pathEnv: '',
      );
      expect(r.resolveProbe(), r'C:\app\ffprobe.exe');
    });

    test('Ffmpeg.resolveProbe delegates to the active resolver', () {
      Ffmpeg.resolver = FfmpegResolver(
        fileExists: (p) => p == '/usr/local/bin/ffmpeg',
        pathEnv: '',
      );
      addTearDown(Ffmpeg.resetForTesting);
      expect(Ffmpeg.resolveProbe(), '/usr/local/bin/ffprobe');
    });
  });
}
