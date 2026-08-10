@TestOn('vm')
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show Offset, Paint, Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/scene_motion_blur.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'shader renders an out-and-back trajectory with a static endpoint',
    () async {
      final source = await _stripedImage();
      final program = await SceneMotionBlurShader.ensureLoaded();
      try {
        const still = SceneMotionBlurSignal(
          scaleDelta: 0,
          translation: Offset.zero,
        );
        const outAndBack = SceneMotionBlurSignal(
          scaleDelta: 0,
          translation: Offset.zero,
          trajectory: <SceneMotionBlurKnot>[
            SceneMotionBlurKnot(scaleDelta: 0, translation: Offset(-12, 0)),
            SceneMotionBlurKnot(scaleDelta: 0, translation: Offset.zero),
            SceneMotionBlurKnot(scaleDelta: 0, translation: Offset(12, 0)),
            SceneMotionBlurKnot(scaleDelta: 0, translation: Offset.zero),
          ],
        );

        expect(outAndBack.hasMotion, isTrue);
        final stillBytes = await _render(source, program, still);
        final trajectoryBytes = await _render(source, program, outAndBack);

        expect(
          trajectoryBytes,
          isNot(orderedEquals(stillBytes)),
          reason:
              'intermediate camera poses must affect the output even when the '
              'shutter endpoint returns to the current pose',
        );
      } finally {
        source.dispose();
      }
    },
  );

  test(
    'moving foreground edge produces a directional coverage trail',
    () async {
      final source = await _hardEdgeImage();
      final program = await SceneMotionBlurShader.ensureLoaded();
      try {
        const signal = SceneMotionBlurSignal(
          scaleDelta: 0,
          translation: Offset(12, 0),
        );
        final bytes = await _render(source, program, signal);

        int alphaAt(int x, int y) => bytes[(y * 64 + x) * 4 + 3];

        expect(alphaAt(32, 32), 255);
        expect(
          alphaAt(48, 32),
          allOf(greaterThan(0), lessThan(255)),
          reason:
              'the swept edge must retain partial temporal coverage outside '
              'the current sharp silhouette instead of being dstIn-clipped',
        );
        expect(
          alphaAt(48, 8),
          0,
          reason: 'coverage may extend only along the actual motion path',
        );
      } finally {
        source.dispose();
      }
    },
  );
}

Future<ui.Image> _stripedImage() async {
  const size = 64.0;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, size, size),
    Paint()..color = const ui.Color(0xFF101010),
  );
  for (var x = 0; x < size.toInt(); x += 8) {
    canvas.drawRect(
      Rect.fromLTWH(x.toDouble(), 0, 4, size),
      Paint()..color = const ui.Color(0xFFF0F0F0),
    );
  }
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(size.toInt(), size.toInt());
  } finally {
    picture.dispose();
  }
}

Future<ui.Image> _hardEdgeImage() async {
  const size = 64.0;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
  canvas.drawRect(
    const Rect.fromLTWH(20, 16, 24, 32),
    Paint()..color = const ui.Color(0xFF70D8A0),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(size.toInt(), size.toInt());
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _render(
  ui.Image source,
  ui.FragmentProgram program,
  SceneMotionBlurSignal signal,
) async {
  const size = Size(64, 64);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, Offset.zero & size);
  paintSceneMotionBlur(
    canvas: canvas,
    image: source,
    program: program,
    size: size,
    signal: signal,
    sampleCount: 32,
    speedCurveExp: 1,
    speedCurveRefPx: 48,
    devicePixelRatio: 1,
  );
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return Uint8List.fromList(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}
