import 'package:slipreel_engine/audio/music_track.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:screen_recorder/audio/music_library.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late PathProviderPlatform previous;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('music-import-test');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
  });
  tearDown(() async {
    PathProviderPlatform.instance = previous;
    await dir.delete(recursive: true);
  });
  test(
    'imports an immutable copy, deduplicates, and rejects non-audio',
    () async {
      final source = '${dir.path}/my audio.wav';
      final result = await Process.run(Ffmpeg.resolve(), [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=duration=1',
        source,
      ]);
      expect(result.exitCode, 0);
      final track = await importMusic(source);
      expect(track.name, 'my audio');
      expect(track.sourceDuration, closeTo(1, 0.01));
      expect((await importMusic(source)).path, track.path);
      await File(source).delete();
      expect(await File(track.path).exists(), isTrue);
      final invalid = await File(
        '${dir.path}/invalid.wav',
      ).writeAsString('not audio');
      await expectLater(importMusic(invalid.path), throwsFormatException);
    },
  );
  test(
    'retires only exact generated preset copies, preserving custom imports',
    () {
      final old = MusicTrack(
        path: '/music/${retiredGeneratedMusicFiles.first}',
        name: 'Lo-Fi',
        preset: 'Lo-Fi',
        sourceDuration: 20,
      );
      expect(isRetiredGeneratedMusic(old), isTrue);
      expect(
        isRetiredGeneratedMusic(
          MusicTrack(path: old.path, name: 'Custom', sourceDuration: 20),
        ),
        isFalse,
      );
      expect(
        isRetiredGeneratedMusic(
          const MusicTrack(
            path: '/music/user.m4a',
            name: 'Lo-Fi',
            preset: 'Lo-Fi',
            sourceDuration: 20,
          ),
        ),
        isFalse,
      );
    },
  );
  test('all library presets resolve to playable library files', () async {
    final paths = <String>{};
    for (final preset in musicPresets) {
      final track = await loadMusicPreset(preset);
      expect(track.preset, preset);
      expect(track.loop, isFalse);
      expect(track.trimStart, musicPresetAudibleStarts[preset]);
      expect(musicPresetCredits[preset], isNotNull);
      expect(track.sourceDuration, greaterThan(10));
      expect(await File(track.path).exists(), isTrue);
      paths.add(track.path);
    }
    expect(paths.length, musicPresets.length);
  });
  test('only untouched built-in starts skip their source silence', () {
    const vaporware = MusicTrack(
      path: '/music/vaporware.m4a',
      name: 'Vaporware',
      preset: 'Vaporware',
      sourceDuration: 165,
    );
    expect(skipPresetLeadingSilence(vaporware).trimStart, 1.70);
    expect(
      skipPresetLeadingSilence(vaporware.copyWith(trimStart: 4)).trimStart,
      4,
    );
    expect(
      skipPresetLeadingSilence(
        const MusicTrack(
          path: '/music/custom.m4a',
          name: 'Custom',
          sourceDuration: 165,
        ),
      ).trimStart,
      0,
    );
  });
}
