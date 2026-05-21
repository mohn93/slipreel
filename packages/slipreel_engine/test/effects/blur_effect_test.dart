import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/blur_effect.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BlurEffect', () {
    test('should blur the frame', () async {
      final effect = BlurEffect(sigmaX: 5.0, sigmaY: 5.0);
      await effect.initialize();

      // Create a frame with a white square in the center
      final frameData = Uint8List(100 * 100 * 4);
      for (int y = 40; y < 60; y++) {
        for (int x = 40; x < 60; x++) {
          final index = (y * 100 + x) * 4;
          frameData[index] = 255;     // B
          frameData[index + 1] = 255; // G
          frameData[index + 2] = 255; // R
          frameData[index + 3] = 255; // A
        }
      }

      final result = await effect.apply(
        frameData: frameData,
        width: 100,
        height: 100,
      );

      expect(result.length, 100 * 100 * 4);

      // Verify blur occurred (edges should have intermediate values)
      final centerIndex = (50 * 100 + 50) * 4;
      final edgeIndex = (39 * 100 + 50) * 4;

      // Center should still be bright
      expect(result[centerIndex], greaterThan(200));

      // Edge should be dimmer (blurred)
      expect(result[edgeIndex], lessThan(200));
      expect(result[edgeIndex], greaterThan(0));

      effect.dispose();
    });
  });
}
