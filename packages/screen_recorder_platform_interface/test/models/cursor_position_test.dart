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

    test('round-trips state through JSON', () {
      const cursor = CursorPosition(
        x: 1,
        y: 2,
        timestampMicros: 3,
        state: CursorState.iBeam,
      );
      final json = cursor.toJson();
      expect(json['state'], 'iBeam');
      final back = CursorPosition.fromJson(json);
      expect(back.state, CursorState.iBeam);
    });

    test('legacy JSON without a state field defaults to arrow', () {
      // Recordings made before the state field existed have no
      // `state` key. fromJson must read these without crashing AND
      // pick CursorState.arrow as the implicit default — anything
      // else would silently corrupt how the editor renders old clips.
      final json = {
        'x': 0.0,
        'y': 0.0,
        'timestampMicros': 0,
        'isClicked': false,
      };
      final cursor = CursorPosition.fromJson(json);
      expect(cursor.state, CursorState.arrow);
    });

    test('unknown state wire name falls back to arrow', () {
      // Forwards-compat: a future-version recording that adds a new
      // state value should load on older code as arrow rather than
      // crashing.
      final json = {
        'x': 0.0,
        'y': 0.0,
        'timestampMicros': 0,
        'state': 'someFutureCursor',
      };
      final cursor = CursorPosition.fromJson(json);
      expect(cursor.state, CursorState.arrow);
    });

    test('every CursorState round-trips through wire encoding', () {
      for (final state in CursorState.values) {
        expect(CursorStateWire.fromWireName(state.wireName), state,
            reason: '${state.name} did not round-trip');
      }
    });
  });
}
