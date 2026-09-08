import 'music_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/export/n_slice_filter_graph.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:video_player/video_player.dart';
import 'package:slipreel_engine/audio/music_graph.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';

final musicPreviewStatusProvider = StateProvider<String?>((ref) => null);

/// Owns the processed music preview, including cancellation on edits/navigation.
class MusicPreview {
  MusicPreview({
    required this.sourcePath,
    required this.onError,
    required this.onReady,
    required this.onActive,
    required this.onStatus,
    this.nowForTesting,
  });
  final String sourcePath;
  final void Function(String) onError;
  final void Function() onReady;
  final void Function(bool) onActive;
  final void Function(String?) onStatus;
  bool get active => _player != null;
  VideoPlayerController? _player;
  VideoPlayerController? _recordingPlayer;
  double _musicGain = 0;
  Process? _process;
  Directory? _folder;
  Timer? _debounce;
  int _generation = 0;
  bool _disposed = false;
  String? _key;
  bool _syncing = false;
  MusicTransport _transport = MusicTransport();
  final Stopwatch _transportClock = Stopwatch()..start();
  final Duration Function()? nowForTesting;
  ({Duration position, bool playing, double speed, int revision})? _lastSync;
  ({Duration position, bool playing, double speed, int revision})? _pendingSync;

  void update(EditorProjectState state, List<AudioStreamInfo> streams) {
    if (_disposed) return;
    final music = state.timeline.music;
    final gain = music == null || music.muted ? 0.0 : music.volume;
    if (gain != _musicGain) {
      _musicGain = gain;
      unawaited(_applyLiveVolume());
    }
    final key = jsonEncode({
      // Gain and mute are live mixer controls, never render/cache inputs.
      'music': music?.copyWith(volume: 1, muted: false).toJson(),
      'clips': state.timeline.clips.map((c) => c.toJson()).toList(),
      'streams': streams
          .map((s) => [s.index, s.startMicros, s.channels])
          .toList(),
    });
    if (_key == key || _disposed) return;
    _key = key;
    final generation = ++_generation;
    _debounce?.cancel();
    _process?.kill();

    if (music == null) {
      _clearCurrentPreview();
      return;
    }

    // Keep the current stems running while an edit is rendered. Controls stay
    // responsive and the replacement is installed only after it is ready.
    if (!active) {
      onStatus('Preparing audio preview…');
    }
    _debounce = Timer(
      const Duration(milliseconds: 150),
      () => _prepare(state, streams, generation),
    );
  }

  void _clearCurrentPreview() {
    final player = _player;
    final recordingPlayer = _recordingPlayer;
    final folder = _folder;
    _player = null;
    _recordingPlayer = null;
    _folder = null;
    _pendingSync = null;
    onActive(false);
    onStatus(null);
    unawaited(_disposeResources(player, recordingPlayer, folder));
  }

  Future<void> _prepare(
    EditorProjectState state,
    List<AudioStreamInfo> streams,
    int generation,
  ) async {
    Directory? folder;
    VideoPlayerController? player;
    VideoPlayerController? recordingPlayer;
    try {
      final track = state.timeline.music;
      final duration =
          totalEditedDuration(state.timeline.clips).inMicroseconds / 1e6;
      if (track == null || duration <= 0) {
        onStatus(null);
        return;
      }
      folder = await Directory.systemTemp.createTemp('slipreel-music-preview-');
      if (_disposed || generation != _generation) return;
      final output = '${folder.path}/music.wav';
      final recording = buildExportFilterGraph(
        state: state,
        audioStreams: streams,
        includeVideo: false,
      );
      final recordingOutput = '${folder.path}/recording.wav';
      final hasMusic = track.segmentDuration > 0 && track.length(duration) > 0;
      // Render separate stems. Music carries fixed 2x headroom in float PCM;
      // native volume (0..1) then covers the editor's 0..200% without clipping
      // the cached samples or changing the microphone/system mix.
      final musicGraph = hasMusic
          ? buildMusicGraph(
              track: track.copyWith(volume: 2, muted: false),
              duration: duration,
              clips: state.timeline.clips,
              streams: streams,
              musicInput: 0,
              recordingInput: 1,
            )
          : 'anullsrc=r=48000:cl=stereo,atrim=duration=$duration[music]';
      final graph = [
        if (recording.filterComplex.isNotEmpty) recording.filterComplex,
        musicGraph,
      ].join(';');
      final process = await Process.start(Ffmpeg.resolve(), [
        '-v',
        'error',
        '-y',
        '-i',
        hasMusic ? track.path : sourcePath,
        '-i',
        sourcePath,
        '-filter_complex',
        graph,
        '-map',
        '[music]',
        '-c:a',
        'pcm_f32le',
        output,
        if (recording.audioMapLabel != null) ...[
          '-map',
          recording.audioMapLabel!,
          '-c:a',
          'pcm_f32le',
          recordingOutput,
        ],
      ]);
      if (_disposed || generation != _generation) {
        process.kill();
      } else {
        _process = process;
      }
      final stderr = process.stderr.transform(utf8.decoder).join();
      final stdout = process.stdout.drain<void>();
      final code = await process.exitCode;
      final error = await stderr;
      await stdout;
      if (identical(_process, process)) _process = null;
      if (_disposed || generation != _generation) return;
      if (code != 0) throw StateError(error);
      player = VideoPlayerController.file(File(output));
      await player.initialize();
      await player.setVolume(0);
      if (recording.audioMapLabel != null) {
        recordingPlayer = VideoPlayerController.file(File(recordingOutput));
        await recordingPlayer.initialize();
        await recordingPlayer.setVolume(0);
      }
      if (_disposed || generation != _generation) return;

      final request = _lastSync;
      final desired = request == null
          ? Duration.zero
          : request.position < Duration.zero
          ? Duration.zero
          : request.position > player.value.duration
          ? player.value.duration
          : request.position;
      final shouldPlay =
          request?.playing == true && desired < player.value.duration;
      final newPlayers = [player, if (recordingPlayer != null) recordingPlayer];
      if (desired != Duration.zero) {
        await Future.wait(newPlayers.map((p) => p.seekTo(desired)));
      }
      if (_disposed || generation != _generation) return;

      final oldPlayer = _player;
      final oldRecordingPlayer = _recordingPlayer;
      final oldFolder = _folder;
      final oldPlayers = [
        if (oldPlayer != null) oldPlayer,
        if (oldRecordingPlayer != null) oldRecordingPlayer,
      ];
      // Silence and stop the prior pair immediately before the replacement is
      // started. Rendering and initialization have already completed, so this
      // swap does not expose the FFmpeg preparation time to playback.
      await Future.wait(oldPlayers.map((p) => p.setVolume(0)));
      await Future.wait(
        oldPlayers.where((p) => p.value.isPlaying).map((p) => p.pause()),
      );

      _folder = folder;
      folder = null;
      _player = player;
      _recordingPlayer = recordingPlayer;
      final installedPlayer = player;
      final installedRecordingPlayer = recordingPlayer;
      player = null;
      recordingPlayer = null;

      await _applyLiveVolume();
      await installedRecordingPlayer?.setVolume(1);
      if (shouldPlay) {
        await Future.wait([
          installedPlayer.play(),
          if (installedRecordingPlayer != null) installedRecordingPlayer.play(),
        ]);
      }
      if (request != null && request.speed != 1) {
        await Future.wait([
          installedPlayer.setPlaybackSpeed(request.speed),
          if (installedRecordingPlayer != null)
            installedRecordingPlayer.setPlaybackSpeed(request.speed),
        ]);
      }
      _transport = MusicTransport();
      if (request != null) {
        _transport.needsSeek(
          position: desired,
          now: nowForTesting?.call() ?? _transportClock.elapsed,
          playing: shouldPlay,
          speed: request.speed,
          seekRevision: request.revision,
        );
      }
      onActive(true);
      onStatus(null);
      onReady();
      unawaited(_disposeResources(oldPlayer, oldRecordingPlayer, oldFolder));
    } catch (e) {
      if (!_disposed && generation == _generation) {
        onStatus(active ? null : 'Audio preview unavailable');
        onError('Music preview could not load. Try replacing the audio.');
      }
    } finally {
      await player?.dispose();
      await recordingPlayer?.dispose();
      if (folder != null && await folder.exists()) {
        await folder.delete(recursive: true);
      }
    }
  }

  Future<void> _applyLiveVolume() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.setVolume((_musicGain / 2).clamp(0.0, 1.0));
    } catch (_) {
      // A structural edit or navigation may have disposed the old stem.
    }
  }

  Future<void> sync(
    Duration position,
    bool playing,
    double speed, {
    int seekRevision = 0,
  }) async {
    if (_disposed) return;
    _lastSync = (
      position: position,
      playing: playing,
      speed: speed,
      revision: seekRevision,
    );
    if (_player == null) return;
    // Keep the latest command while a native seek is pending. In particular,
    // a pause or a second scrub must not be dropped by the reentrancy guard.
    _pendingSync = (
      position: position,
      playing: playing,
      speed: speed,
      revision: seekRevision,
    );
    if (_syncing) return;
    _syncing = true;
    try {
      while (_pendingSync != null && !_disposed) {
        final request = _pendingSync!;
        _pendingSync = null;
        final player = _player;
        if (player == null || !player.value.isInitialized) continue;
        final desired = request.position < Duration.zero
            ? Duration.zero
            : request.position > player.value.duration
            ? player.value.duration
            : request.position;
        final shouldPlay = request.playing && desired < player.value.duration;
        final seek = _transport.needsSeek(
          position: desired,
          now: nowForTesting?.call() ?? _transportClock.elapsed,
          playing: shouldPlay,
          speed: request.speed,
          seekRevision: request.revision,
        );
        final players = [
          player,
          if (_recordingPlayer != null) _recordingPlayer!,
        ];
        bool current() => !_disposed && identical(_player, player);
        try {
          if (!shouldPlay) {
            await Future.wait(
              players.where((p) => p.value.isPlaying).map((p) => p.pause()),
            );
          }
          if (!current()) continue;
          if (seek) await Future.wait(players.map((p) => p.seekTo(desired)));
          if (!current()) continue;
          // A newer command owns the transport now; don't start stale playback.
          if (_pendingSync != null) continue;
          if (shouldPlay) {
            await Future.wait(
              players.where((p) => !p.value.isPlaying).map((p) => p.play()),
            );
          }
          if (!current()) continue;
          await Future.wait(
            players
                .where((p) => p.value.playbackSpeed != request.speed)
                .map((p) => p.setPlaybackSpeed(request.speed)),
          );
        } catch (_) {
          // A newer edit may have disposed this player.
        }
      }
    } finally {
      _syncing = false;
    }
  }

  void dispose() {
    _disposed = true;
    ++_generation;
    _pendingSync = null;
    _debounce?.cancel();
    _process?.kill();
    final player = _player;
    final recordingPlayer = _recordingPlayer;
    _recordingPlayer = null;
    _player = null;
    final folder = _folder;
    _folder = null;
    unawaited(_disposeResources(player, recordingPlayer, folder));
  }

  Future<void> _disposeResources(
    VideoPlayerController? player,
    VideoPlayerController? recordingPlayer,
    Directory? folder,
  ) async {
    // Mute and pause before disposing. On macOS/AVFoundation, disposing a
    // still-playing controller does not reliably cut its audio right away, so
    // leaving the editor while music is playing would keep the stem audible
    // back on the recordings list. Muting is the instant stop; pausing tears
    // down the render pipeline; both are best-effort since a structural edit
    // may already have disposed the controller.
    for (final p in [player, recordingPlayer]) {
      if (p == null) continue;
      try {
        await p.setVolume(0);
        if (p.value.isInitialized && p.value.isPlaying) await p.pause();
      } catch (_) {}
    }
    await player?.dispose();
    await recordingPlayer?.dispose();
    if (folder != null && await folder.exists()) {
      await folder.delete(recursive: true);
    }
  }
}
