import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/gradient_effect.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GradientEffect', () {
    test('should create gradient with two colors', () async {
      final effect = GradientEffect(
        colors: [Colors.blue, Colors.purple],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      );

      await effect.initialize();

      final result = await effect.apply(
        frameData: Uint8List(100 * 100 * 4),
        width: 100,
        height: 100,
      );

      expect(result.length, 100 * 100 * 4);

      // Verify gradient was created by checking top and bottom pixels
      // Top pixel (first pixel) - should be close to blue
      final topB = result[0];
      final topG = result[1];
      final topR = result[2];

      // Bottom pixel (last pixel) - should be close to purple
      final bottomB = result[result.length - 4];
      final bottomG = result[result.length - 3];
      final bottomR = result[result.length - 2];

      // Blue is RGB(33, 150, 243) -> BGRA(243, 150, 33, 255)
      // Purple is RGB(156, 39, 176) -> BGRA(176, 39, 156, 255)

      // Top should have more blue (higher B and G values than bottom)
      expect(topB, greaterThan(bottomB), reason: 'Top should have more blue component');
      expect(topG, greaterThan(bottomG), reason: 'Top should have more green component');

      // Bottom should have more red (higher R value than top)
      expect(bottomR, greaterThan(topR), reason: 'Bottom should have more red component');

      effect.dispose();
    });
  });
}
