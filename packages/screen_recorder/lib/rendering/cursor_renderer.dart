import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/services.dart';
import '../models/cursor_recording.dart';
import '../effects/background_effect.dart';
import '../utils/app_logger.dart';

/// Renders cursor overlay on video frames
class CursorRenderer {
  ui.Image? _defaultCursor;
  ui.Image? _clickCursor;
  bool _isInitialized = false;
  BackgroundEffect? _backgroundEffect;

  /// Initialize cursor images
  Future<void> initialize() async {
    try {
      // Load default cursor
      final defaultData = await rootBundle.load('assets/cursors/default_cursor.png');
      _defaultCursor = await _loadImage(defaultData.buffer.asUint8List());

      // Load click cursor
      final clickData = await rootBundle.load('assets/cursors/click_cursor.png');
      _clickCursor = await _loadImage(clickData.buffer.asUint8List());

      _isInitialized = true;
    } catch (e) {
      _isInitialized = false;
      throw Exception('Failed to initialize cursor renderer: $e');
    }
  }

  Future<ui.Image> _loadImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  /// Set background effect to apply before cursor
  Future<void> setBackgroundEffect(BackgroundEffect? effect) async {
    _backgroundEffect?.dispose();
    _backgroundEffect = effect;
    if (effect != null) {
      await effect.initialize();
    }
  }

  /// Draw cursor on frame at specific timestamp
  Future<Uint8List> renderCursorOnFrame({
    required Uint8List frameData,
    required int width,
    required int height,
    required int timestampMicros,
    required CursorRecording cursorRecording,
  }) async {
    if (!_isInitialized) {
      throw StateError('CursorRenderer not initialized');
    }

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

      // Validate cursors loaded
      if (_defaultCursor == null || _clickCursor == null) {
        throw StateError('Cursor images not loaded');
      }

      // Convert BGRA frame data to Image
      final frameImage = await _createImageFromBGRA(processedFrame, width, height);

      // Create canvas to draw on
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      // Draw original frame
      canvas.drawImage(frameImage, ui.Offset.zero, ui.Paint());

      // Draw cursor at position
      final cursorImage = cursorPos.isClicked ? _clickCursor! : _defaultCursor!;
      final cursorOffset = ui.Offset(
        cursorPos.x - cursorImage.width / 2,
        cursorPos.y - cursorImage.height / 2,
      );
      canvas.drawImage(cursorImage, cursorOffset, ui.Paint());

      // Convert back to BGRA bytes
      final picture = recorder.endRecording();
      final img = await picture.toImage(width, height);
      final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);

      // Convert RGBA to BGRA
      final rgbaBytes = byteData!.buffer.asUint8List();
      final bgraBytes = Uint8List(rgbaBytes.length);

      for (int i = 0; i < rgbaBytes.length; i += 4) {
        bgraBytes[i] = rgbaBytes[i + 2];     // B
        bgraBytes[i + 1] = rgbaBytes[i + 1]; // G
        bgraBytes[i + 2] = rgbaBytes[i];     // R
        bgraBytes[i + 3] = rgbaBytes[i + 3]; // A
      }

      return bgraBytes;
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
    _defaultCursor?.dispose();
    _clickCursor?.dispose();
    _backgroundEffect?.dispose();
    _backgroundEffect = null;
    _isInitialized = false;
  }
}
