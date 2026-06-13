import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/services.dart';
import '../models/cursor_recording.dart';
import '../effects/background_effect.dart';
import '../utils/app_logger.dart';
import 'cursor_click_effect.dart';
import 'cursor_glyph.dart';
import 'cursor_painter.dart';
import 'spring_config.dart';

/// Renders cursor overlay on video frames during export. The glyph is
/// drawn programmatically via [paintCursorComposed] so the exported
/// video matches the editor's playback overlay (size, style, and click
/// effect) frame-for-frame.
class CursorRenderer {
  final double sizeMultiplier;
  final CursorStyle style;
  final CursorClickEffect clickEffect;
  final ClickSpring clickSpring;
  BackgroundEffect? _backgroundEffect;

  CursorRenderer({
    this.sizeMultiplier = 1.0,
    this.style = CursorStyle.modernDark,
    this.clickEffect = CursorClickEffect.ripple,
    this.clickSpring = ClickSpring.snappy,
  });

  /// No-op kept for source-compat with earlier asset-loading API.
  Future<void> initialize() async {}

  /// Set background effect to apply before cursor
  Future<void> setBackgroundEffect(BackgroundEffect? effect) async {
    _backgroundEffect?.dispose();
    _backgroundEffect = effect;
    if (effect != null) {
      await effect.initialize();
    }
  }

  /// Draw cursor on frame at specific timestamp.
  Future<Uint8List> renderCursorOnFrame({
    required Uint8List frameData,
    required int width,
    required int height,
    required int timestampMicros,
    required CursorRecording cursorRecording,
  }) async {
    try {
      // Apply background effect first (if set)
      Uint8List processedFrame = frameData;
      if (_backgroundEffect != null) {
        processedFrame = await _backgroundEffect!.apply(
          frameData: frameData,
          width: width,
          height: height,
        );
      }

      // Get cursor position at this timestamp
      final cursorPos = cursorRecording.getPositionAt(timestampMicros);
      if (cursorPos == null) {
        // No cursor data, return processed frame
        return processedFrame;
      }

      // Convert BGRA frame data to Image
      final frameImage = await _createImageFromBGRA(processedFrame, width, height);

      // m13: dispose the frame image, picture, and output image — they are
      // native handles allocated every frame and otherwise leak until GC.
      ui.Picture? picture;
      ui.Image? img;
      try {
        // Create canvas to draw on
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);

        // Draw original frame
        canvas.drawImage(frameImage, ui.Offset.zero, ui.Paint());

        // Draw the synthetic cursor at the recorded position. The cursor
        // recording stores positions in screen-space pixels; for the
        // export, screen-space matches video-space (we encode at the
        // capture's native dimensions).
        //
        // The ripple is anchored to where the click *landed*, not to the
        // current cursor position, so click-and-drag in the recording
        // doesn't drag the ring around (bug #1 from the 2026-05
        // architecture review — the legacy `paintCursorWithEffects`
        // wrapper conflated both positions).
        final clickEvent =
            mostRecentClickEvent(cursorRecording, timestampMicros);
        final int? dt = clickEvent == null
            ? null
            : timestampMicros - clickEvent.timestampMicros;
        final dtRelease =
            microsSinceRelease(cursorRecording, timestampMicros);
        paintCursorComposed(
          canvas,
          CursorPaintRequest(
            cursorPosition: ui.Offset(cursorPos.x, cursorPos.y),
            clickPosition: clickEvent?.screenPos,
            microsSinceClick: dt,
            microsSinceRelease: dtRelease,
            baseDiameter: kCursorBaseDiameter * sizeMultiplier,
            style: style,
            clickSpring: clickSpring,
            clickEffect: clickEffect,
          ),
        );

        // Convert back to BGRA bytes
        picture = recorder.endRecording();
        img = await picture.toImage(width, height);
        final byteData =
            await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (byteData == null) {
          // Don't crash the encode on a null raster — ship the frame as-is.
          AppLogger.cursorRenderer
              .w('cursor frame toByteData returned null; using source frame');
          return processedFrame;
        }

        // Convert RGBA to BGRA
        final rgbaBytes = byteData.buffer.asUint8List();
        final bgraBytes = Uint8List(rgbaBytes.length);

        for (int i = 0; i < rgbaBytes.length; i += 4) {
          bgraBytes[i] = rgbaBytes[i + 2];     // B
          bgraBytes[i + 1] = rgbaBytes[i + 1]; // G
          bgraBytes[i + 2] = rgbaBytes[i];     // R
          bgraBytes[i + 3] = rgbaBytes[i + 3]; // A
        }

        return bgraBytes;
      } finally {
        frameImage.dispose();
        picture?.dispose();
        img?.dispose();
      }
    } catch (e) {
      AppLogger.cursorRenderer.e('Error rendering cursor on frame', error: e);
      return frameData; // Return original frame to avoid breaking encoding
    }
  }

  Future<ui.Image> _createImageFromBGRA(Uint8List bgra, int width, int height) async {
    // Convert BGRA to RGBA for Flutter
    final rgba = Uint8List(bgra.length);
    for (int i = 0; i < bgra.length; i += 4) {
      rgba[i] = bgra[i + 2];     // R
      rgba[i + 1] = bgra[i + 1]; // G
      rgba[i + 2] = bgra[i];     // B
      rgba[i + 3] = bgra[i + 3]; // A
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (ui.Image image) {
        completer.complete(image);
      },
    );
    return completer.future;
  }

  /// Dispose resources
  void dispose() {
    _backgroundEffect?.dispose();
    _backgroundEffect = null;
  }
}
