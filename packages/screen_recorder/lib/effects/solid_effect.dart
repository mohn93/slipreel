import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'background_effect.dart';

/// Solid color background effect
class SolidEffect implements BackgroundEffect {
  final Color color;

  SolidEffect({required this.color});

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
    final result = Uint8List(width * height * 4);

    // Extract color components
    final b = color.blue;
    final g = color.green;
    final r = color.red;
    final a = color.alpha;

    // Fill with solid color in BGRA format
    for (int i = 0; i < result.length; i += 4) {
      result[i] = b;
      result[i + 1] = g;
      result[i + 2] = r;
      result[i + 3] = a;
    }

    return result;
  }
}
