import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/solid_effect.dart';

void main() {
  group('SolidEffect', () {
    test('should fill frame with solid color', () async {
      final effect = SolidEffect(color: const Color(0xFFFF0000)); // Pure red
      await effect.initialize();

      final result = await effect.apply(
        frameData: Uint8List(100 * 100 * 4),
        width: 100,
        height: 100,
      );

      expect(result.length, 100 * 100 * 4);

      // Check first pixel is red (in BGRA format)
      expect(result[0], 0);   // B = 0
      expect(result[1], 0);   // G = 0
      expect(result[2], 255); // R = 255
      expect(result[3], 255); // A = 255

      effect.dispose();
    });
  });
}
