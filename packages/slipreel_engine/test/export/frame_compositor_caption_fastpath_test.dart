import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

/// Regression test for: export drops captions on the no-wallpaper /
/// no-chrome / no-camera fast path.
///
/// When the window frame is "None" (chromeImage == null), there is no
/// wallpaper, and no camera, compose() used to return fgToComposite
/// directly — BEFORE the CaptionRenderer.paint call — so active captions
/// were silently dropped from the exported bytes.
///
/// The fix adds `!captionsActive` to the early-return guard.  This test
/// catches a regression by composing the same frame twice (once with
/// captions enabled + active, once disabled) and asserting the bytes
/// differ; if they are equal the caption was silently dropped.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const videoW = 8;
  const videoH = 4;
  const positionUs = 500000; // 500 ms

  // A segment that spans 0..1s so it is active at positionUs.
  const activeSegment = CaptionSegment(
    id: 'cap1',
    startMicros: 0,
    endMicros: 1000000,
    text: 'Hello',
  );

  FrameCompositor build({required bool captionsEnabled}) {
    return FrameCompositor(
      projectState: EditorProjectState.defaults().copyWith(
        windowFrame: WindowFrame.none(),
        captionStyle: CaptionStyle(enabled: captionsEnabled),
        captionSegments: captionsEnabled ? const [activeSegment] : const [],
      ),
      cursorRecording: CursorRecording(),
      metadata: RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.now(),
        widthPx: videoW,
        heightPx: videoH,
        fps: 30,
      ),
      videoSize: const Size(8, 4),
      fps: 30,
    );
  }

  // Solid mid-grey BGRA frame — chosen so the caption text (white on dark
  // background) visibly alters bytes in the small 8×4 canvas.
  Uint8List greyBgra() {
    final px = videoW * videoH;
    final out = Uint8List(px * 4);
    for (var i = 0; i < px; i++) {
      out[i * 4 + 0] = 0x80; // B
      out[i * 4 + 1] = 0x80; // G
      out[i * 4 + 2] = 0x80; // R
      out[i * 4 + 3] = 0xFF; // A
    }
    return out;
  }

  test(
    'no-wallpaper/no-chrome/no-camera: active captions change the exported '
    'bytes (fast-path must not be taken when captions are active)',
    () async {
      final withCaptions = build(captionsEnabled: true);
      final withoutCaptions = build(captionsEnabled: false);

      const pos = Duration(microseconds: positionUs);
      final rgbaWith =
          await withCaptions.compose(videoFrameBgra: greyBgra(), position: pos);
      final rgbaWithout =
          await withoutCaptions.compose(videoFrameBgra: greyBgra(), position: pos);

      // Both must be the expected byte length.
      expect(rgbaWith.length, videoW * videoH * 4);
      expect(rgbaWithout.length, videoW * videoH * 4);

      // The bytes must differ — at least one pixel was painted by the
      // caption renderer.
      final differ = rgbaWith
          .asMap()
          .entries
          .any((e) => e.value != rgbaWithout[e.key]);
      expect(
        differ,
        isTrue,
        reason:
            'caption-enabled and caption-disabled exports produced identical '
            'bytes — captions were silently dropped on the fast path',
      );
    },
  );
}
