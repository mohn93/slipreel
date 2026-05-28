import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Paint;
import 'background_effect.dart';

/// Blur background effect
class BlurEffect implements BackgroundEffect {
  final double sigmaX;
  final double sigmaY;

  BlurEffect({
    this.sigmaX = 10.0,
    this.sigmaY = 10.0,
  }) {
    if (sigmaX < 0) {
      throw ArgumentError('sigmaX must be non-negative');
    }
    if (sigmaY < 0) {
      throw ArgumentError('sigmaY must be non-negative');
    }
  }

  @override
  Future<void> initialize() async {
    // No initialization needed
  }

  @override
  void dispose() {
    // Nothing to dispose
  }

  @override
  Future<Uint8List> apply({
    required Uint8List frameData,
    required int width,
    required int height,
  }) async {
    // Convert BGRA to RGBA
    final rgba = Uint8List(frameData.length);
    for (int i = 0; i < frameData.length; i += 4) {
      rgba[i] = frameData[i + 2];     // R
      rgba[i + 1] = frameData[i + 1]; // G
      rgba[i + 2] = frameData[i];     // B
      rgba[i + 3] = frameData[i + 3]; // A
    }

    // Create image from RGBA data
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
    final inputImage = await completer.future;

    // Apply blur using Canvas
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    final paint = Paint()
      ..imageFilter = ui.ImageFilter.blur(sigmaX: sigmaX, sigmaY: sigmaY);

    canvas.drawImage(inputImage, ui.Offset.zero, paint);

    final picture = recorder.endRecording();
    final blurredImage = await picture.toImage(width, height);

    // Convert back to BGRA
    final byteData = await blurredImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) {
      throw Exception('Failed to convert blurred image to bytes');
    }

    final rgbaOutput = byteData.buffer.asUint8List();
    final bgraOutput = Uint8List(rgbaOutput.length);
    for (int i = 0; i < rgbaOutput.length; i += 4) {
      bgraOutput[i] = rgbaOutput[i + 2];     // B
      bgraOutput[i + 1] = rgbaOutput[i + 1]; // G
      bgraOutput[i + 2] = rgbaOutput[i];     // R
      bgraOutput[i + 3] = rgbaOutput[i + 3]; // A
    }

    return bgraOutput;
  }
}
