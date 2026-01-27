import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/gradient_effect.dart';

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

      effect.dispose();
    });
  });
}
