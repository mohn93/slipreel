import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'background_effect.dart';

/// Gradient background effect
class GradientEffect implements BackgroundEffect {
  final List<Color> colors;
  final Alignment begin;
  final Alignment end;

  GradientEffect({
    required this.colors,
    this.begin = Alignment.topLeft,
    this.end = Alignment.bottomRight,
  }) {
    if (colors.isEmpty) {
      throw ArgumentError('colors must not be empty');
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
    // Create gradient image
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    final gradient = LinearGradient(
      begin: begin,
      end: end,
      colors: colors,
    );

    final paint = Paint()
      ..shader = gradient.createShader(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      );

    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      paint,
    );

    final picture = recorder.endRecording();
    // m12: dispose the picture + rasterized image (native handles); without
    // this each call leaks 1 ui.Picture + 1 ui.Image.
    ui.Image? image;
    try {
      image = await picture.toImage(width, height);

      // Convert to BGRA
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) {
        throw Exception('Failed to convert gradient to bytes');
      }

      // Convert RGBA to BGRA
      final rgba = byteData.buffer.asUint8List();
      final bgra = Uint8List(rgba.length);
      for (int i = 0; i < rgba.length; i += 4) {
        bgra[i] = rgba[i + 2];     // B
        bgra[i + 1] = rgba[i + 1]; // G
        bgra[i + 2] = rgba[i];     // R
        bgra[i + 3] = rgba[i + 3]; // A
      }

      return bgra;
    } finally {
      picture.dispose();
      image?.dispose();
    }
  }
}
