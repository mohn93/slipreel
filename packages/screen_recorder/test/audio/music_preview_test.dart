import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/audio/music_preview.dart';
import 'package:slipreel_engine/audio/music_track.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _AudioPlayer extends VideoPlayerPlatform {
  bool playing = false;
  double speed = 1;
  Duration position = Duration.zero;
  final paths = <String>[];
  final volumes = <int, double>{};
  int disposals = 0;
  int seeks = 0;
  Completer<void>? seekGate;
  @override
  Future<void> init() async {}
  @override
  Future<int?> create(DataSource source) async {
    paths.add(Uri.parse(source.uri!).toFilePath());
    return paths.length;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int id) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 4),
      size: Size.zero,
    ),
  );
  @override
  Future<void> dispose(int id) async {
    disposals++;
  }

  @override
  Future<void> setLooping(int id, bool looping) async {}
  @override
  Future<void> setVolume(int id, double volume) async {
    volumes[id] = volume;
  }

  @override
  Future<void> play(int id) async {
    playing = true;
  }

  @override
  Future<void> pause(int id) async {
    playing = false;
  }

  @override
  Future<void> setPlaybackSpeed(int id, double value) async {
    speed = value;
  }

  @override
  Future<Duration> getPosition(int id) async => position;
  @override
  Future<void> seekTo(int id, Duration value) async {
    seeks++;
    position = value;
    final gate = seekGate;
    seekGate = null;
    await gate?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final withRecording in [false, true]) {
    test(
      'live music gain and transport without reload (recording audio: $withRecording)',
      () async {
        final folder = await Directory.systemTemp.createTemp(
          'music-preview-test',
        );
        final source = '${folder.path}/source.wav';
        final r = await Process.run(Ffmpeg.resolve(), [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=duration=4',
          source,
        ]);
        expect(r.exitCode, 0);
        final old = VideoPlayerPlatform.instance;
        final platform = _AudioPlayer();
        VideoPlayerPlatform.instance = platform;
        final errors = <String>[];
        final statuses = <String?>[];
        var ready = Completer<void>();
        var elapsed = Duration.zero;
        final preview = MusicPreview(
          nowForTesting: () => elapsed,
          sourcePath: source,
          onError: errors.add,
          onReady: () => ready.complete(),
          onActive: (_) {},
          onStatus: statuses.add,
        );
        final state = EditorProjectState.defaults().copyWith(
          timeline: Timeline(
            music: MusicTrack(path: source, name: 'Tone', sourceDuration: 4),
            clips: [
              ClipSlice(
                cutStart: Duration.zero,
                cutEnd: const Duration(seconds: 4),
              ),
            ],
          ),
        );
        final streams = withRecording
            ? const [
                AudioStreamInfo(index: 0, channels: 1, codecName: 'pcm_s16le'),
              ]
            : <AudioStreamInfo>[];
        try {
          preview.update(state, streams);
          await ready.future.timeout(const Duration(seconds: 10));
          expect(preview.active, isTrue);
          expect(await File(platform.paths.first).exists(), isTrue);
          await preview.sync(Duration.zero, true, 1);
          final initialSeeks = platform.seeks;
          // Native audio position remains stale while video sends 60 Hz updates.
          // The old 180 ms clock comparison repeatedly sought and cut the music.
          for (var frame = 1; frame <= 120; frame++) {
            elapsed = Duration(microseconds: frame * 16667);
            await preview.sync(elapsed, true, 1);
          }
          expect(platform.seeks, initialSeeks);
          await preview.sync(
            const Duration(seconds: 2),
            true,
            1.5,
            seekRevision: 1,
          );
          expect(platform.position, const Duration(seconds: 2));
          expect(platform.playing, isTrue);
          expect(platform.speed, 1.5);
          await preview.sync(const Duration(seconds: 3), false, 1);
          expect(platform.playing, isFalse);
          expect(platform.position, const Duration(seconds: 3));
          // A pause arriving during a native seek must win over the old play.
          final gate = Completer<void>();
          platform.seekGate = gate;
          final pending = preview.sync(
            const Duration(milliseconds: 2500),
            true,
            1,
            seekRevision: 2,
          );
          await preview.sync(
            const Duration(milliseconds: 2700),
            false,
            1,
            seekRevision: 3,
          );
          gate.complete();
          await pending;
          expect(platform.position, const Duration(milliseconds: 2700));
          expect(platform.playing, isFalse);
          // Volume/mute changes must not invalidate either stem, touch transport,
          // or show the preparation spinner, even after the old debounce elapses.
          final loadedPaths = platform.paths.toList();
          final seeksBeforeVolume = platform.seeks;
          final statusCount = statuses.length;
          final recordingVolume = platform.volumes[2];
          await preview.sync(
            const Duration(milliseconds: 2700),
            true,
            1,
            seekRevision: 3,
          );
          final playingSeeks = platform.seeks;
          for (final gain in [0.0, 0.2, 0.5, 1.0, 1.5, 2.0]) {
            preview.update(
              state.copyWith(
                timeline: state.timeline.copyWith(
                  music: state.timeline.music!.copyWith(volume: gain),
                ),
              ),
              streams,
            );
            expect(preview.active, isTrue);
            expect(platform.volumes[1], gain / 2);
            expect(platform.volumes[2], recordingVolume);
          }
          preview.update(
            state.copyWith(
              timeline: state.timeline.copyWith(
                music: state.timeline.music!.copyWith(volume: 2, muted: true),
              ),
            ),
            streams,
          );
          expect(platform.volumes[1], 0);
          preview.update(
            state.copyWith(
              timeline: state.timeline.copyWith(
                music: state.timeline.music!.copyWith(volume: 2, muted: false),
              ),
            ),
            streams,
          );
          expect(platform.volumes[1], 1);
          await Future<void>.delayed(const Duration(milliseconds: 450));
          expect(platform.paths, loadedPaths);
          expect(platform.disposals, 0);
          expect(platform.seeks, playingSeeks);
          expect(playingSeeks, greaterThanOrEqualTo(seeksBeforeVolume));
          expect(platform.playing, isTrue);
          expect(statuses.length, statusCount);
          ready = Completer<void>();
          preview.update(
            state.copyWith(
              timeline: state.timeline.copyWith(
                music: state.timeline.music!.copyWith(fadeIn: 0.8),
              ),
            ),
            streams,
          );
          // Structural controls rebuild in the background while the current
          // stems continue to play, then replace them in one short swap.
          expect(preview.active, isTrue);
          expect(platform.playing, isTrue);
          await ready.future.timeout(const Duration(seconds: 10));
          expect(platform.paths.length, withRecording ? 4 : 2);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(await File(platform.paths.first).exists(), isFalse);
          preview.update(
            state.copyWith(timeline: state.timeline.copyWith(clearMusic: true)),
            streams,
          );
          expect(preview.active, isFalse);
          expect(errors, isEmpty);
        } finally {
          preview.dispose();
          // Async player disposal releases the temp audio before the directory is removed.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          VideoPlayerPlatform.instance = old;
          await folder.delete(recursive: true);
        }
        expect(platform.disposals, withRecording ? 4 : 2);
        expect(await File(platform.paths.last).exists(), isFalse);
      },
    );
  }
}
