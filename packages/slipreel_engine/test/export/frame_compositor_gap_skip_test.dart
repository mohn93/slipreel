import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/painting.dart' show Color, EdgeInsets;
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';

/// Slice-aware export skip: frames in trimmed-away gaps are never seen by
/// the user (ffmpeg's per-slice trim drops them), so the pipeline replaces
/// their composition with [FrameCompositor.advanceScenePass] + a blank
/// buffer. The ONLY cross-frame state in the compositor is the shared
/// [ScenePassBuilder] (cursor spring/EMA + emitted-position history that
/// the accumulation cursor painter replays). advanceScenePass must advance
/// exactly that state, so every KEPT frame composes byte-identical to a
/// pipeline that composed the gap frames too.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const videoSize = Size(320, 240);
  const fps = 10;
  const totalFrames = 30; // 3s at 10fps

  // Cursor sweeping the whole 3s so the spring/EMA state is in constant
  // motion — a parked cursor would let a broken advanceScenePass pass.
  CursorRecording sweep() {
    final rec = CursorRecording();
    for (var ms = 0; ms <= 3000; ms += 16) {
      final t = ms / 3000;
      rec.addPosition(
        CursorPosition(
          x: 40.0 + (280 - 40) * t,
          y: 40.0 + (200 - 40) * t,
          timestampMicros: ms * 1000,
        ),
      );
    }
    return rec;
  }

  // Follow zoom spanning the trimmed-away gap: the kept frames AFTER the
  // gap depend on spring state accumulated THROUGH the gap.
  final followRegion = ZoomRegion(
    rect: const Rect.fromLTWH(0, 0, 320, 240),
    startTime: const Duration(milliseconds: 500),
    duration: const Duration(milliseconds: 2200),
    zoomLevel: 2.0,
    followCursor: true,
    followMode: FollowMode.bounded,
  );

  // Keep [0s,1s] and [2s,3s]; the middle second is trimmed away.
  final clips = [
    ClipSlice(
      cutStart: Duration.zero,
      cutEnd: const Duration(seconds: 1),
    ),
    ClipSlice(
      cutStart: const Duration(seconds: 1),
      cutEnd: const Duration(seconds: 3),
      trimStart: const Duration(seconds: 2),
    ),
  ];

  EditorProjectState state() => EditorProjectState.defaults().copyWith(
    windowFrame: const WindowFrame(
      name: 'None',
      padding: EdgeInsets.zero,
      cornerRadius: 0,
      shadowBlur: 0,
      shadowOffset: Offset.zero,
      shadowColor: Color(0x00000000),
      borderWidth: 0,
    ),
    zoomRegions: [followRegion],
    timeline: EditorProjectState.defaults().timeline.copyWith(clips: clips),
    motionBlur: 0.8,
    cursorMovementBlur: 0.8,
  );

  FrameCompositor makeCompositor() => FrameCompositor(
    projectState: state(),
    cursorRecording: sweep(),
    metadata: RecordingMetadata(
      isPureSource: true,
      recordedAt: DateTime(2026),
      widthPx: 320,
      heightPx: 240,
      fps: fps,
    ),
    videoSize: videoSize,
    fps: fps,
  );

  Uint8List solidBgra() {
    final out = Uint8List(320 * 240 * 4);
    for (var i = 0; i < 320 * 240; i++) {
      out[i * 4 + 0] = 0x20;
      out[i * 4 + 1] = 0x80;
      out[i * 4 + 2] = 0xF0;
      out[i * 4 + 3] = 0xFF;
    }
    return out;
  }

  test(
    'advanceScenePass on gap frames keeps kept frames byte-identical',
    () async {
      final margin = Duration(microseconds: 1000000 ~/ fps);
      final frame = solidBgra();

      final full = makeCompositor();
      final skipping = makeCompositor();

      final fullFrames = <int, Uint8List>{};
      final skipFrames = <int, Uint8List>{};
      var skipped = 0;

      for (var i = 0; i < totalFrames; i++) {
        final position = Duration(microseconds: (1000000 * i) ~/ fps);
        final kept = sourceFrameContributes(clips, position, margin: margin);

        fullFrames[i] = await full.compose(
          videoFrameBgra: frame,
          position: position,
        );

        if (kept) {
          skipFrames[i] = await skipping.compose(
            videoFrameBgra: frame,
            position: position,
          );
        } else {
          skipping.advanceScenePass(position);
          skipped++;
        }
      }

      // The fixture must actually exercise the skip path.
      expect(skipped, greaterThanOrEqualTo(5));

      for (final entry in skipFrames.entries) {
        expect(
          entry.value,
          equals(fullFrames[entry.key]),
          reason:
              'kept frame ${entry.key} diverged — advanceScenePass did not '
              'reproduce the state a full composition of the gap frames '
              'would have left behind',
        );
      }
    },
  );

  test('advanceScenePass runs the same state machinery as compose', () {
    // In a trimmed-away gap ScenePassBuilder deliberately RESETS motion
    // (activeClipIndex < 0), so gap positions record no history — that
    // matches compose. Probe an in-slice position instead: a real state
    // advance must feed the emitted-position history the accumulation
    // painter replays.
    final compositor = makeCompositor();
    compositor.advanceScenePass(const Duration(milliseconds: 500));
    expect(
      compositor.cursorHistoryAt(const Duration(milliseconds: 500)),
      isNotNull,
      reason: 'the accumulation painter replays emitted positions through '
          'ScenePassBuilder.motion.positionAt; advanceScenePass must feed it',
    );
  });
}
