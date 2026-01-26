import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('CursorPosition', () {
    test('should serialize to JSON correctly', () {
      final cursor = CursorPosition(
        x: 100.5,
        y: 200.75,
        timestampMicros: 1000000,
        isClicked: true,
      );

      final json = cursor.toJson();

      expect(json['x'], 100.5);
      expect(json['y'], 200.75);
      expect(json['timestampMicros'], 1000000);
      expect(json['isClicked'], true);
    });

    test('should deserialize from JSON correctly', () {
      final json = {
        'x': 150.25,
        'y': 250.5,
        'timestampMicros': 2000000,
        'isClicked': false,
      };

      final cursor = CursorPosition.fromJson(json);

      expect(cursor.x, 150.25);
      expect(cursor.y, 250.5);
      expect(cursor.timestampMicros, 2000000);
      expect(cursor.isClicked, false);
    });

    test('should default isClicked to false', () {
      final json = {
        'x': 50.0,
        'y': 75.0,
        'timestampMicros': 500000,
      };

      final cursor = CursorPosition.fromJson(json);

      expect(cursor.isClicked, false);
    });
  });
}
