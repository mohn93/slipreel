import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/window_frame.dart';

void main() {
  group('WindowFrame', () {
    test('should create frame with all properties', () {
      final frame = WindowFrame(
        name: 'Custom',
        padding: const EdgeInsets.all(20),
        cornerRadius: 12.0,
        shadowBlur: 30.0,
        shadowOffset: const Offset(0, 10),
        shadowColor: const Color(0x33000000),
        backgroundColor: const Color(0xFFFFFFFF),
        borderWidth: 2.0,
        borderColor: const Color(0xFFE0E0E0),
      );

      expect(frame.name, 'Custom');
      expect(frame.padding, const EdgeInsets.all(20));
      expect(frame.cornerRadius, 12.0);
      expect(frame.shadowBlur, 30.0);
      expect(frame.shadowOffset, const Offset(0, 10));
      expect(frame.shadowColor, const Color(0x33000000));
      expect(frame.backgroundColor, const Color(0xFFFFFFFF));
      expect(frame.borderWidth, 2.0);
      expect(frame.borderColor, const Color(0xFFE0E0E0));
    });

    test('should create none template with no decorations', () {
      final frame = WindowFrame.none();

      expect(frame.name, 'None');
      expect(frame.padding, EdgeInsets.zero);
      expect(frame.cornerRadius, 0.0);
      expect(frame.shadowBlur, 0.0);
      expect(frame.shadowOffset, Offset.zero);
      expect(frame.shadowColor, const Color(0x00000000));
      expect(frame.backgroundColor, null);
      expect(frame.borderWidth, 0.0);
      expect(frame.borderColor, null);
    });

    test('should create rounded template', () {
      final frame = WindowFrame.rounded();

      expect(frame.name, 'Rounded');
      expect(frame.padding, const EdgeInsets.all(72));
      expect(frame.cornerRadius, 16.0);
      expect(frame.shadowBlur, 80.0);
      expect(frame.shadowOffset, const Offset(0, 28));
      expect(frame.shadowColor, const Color(0x99000000));
      expect(frame.backgroundColor, null);
      expect(frame.borderWidth, 0.0);
      expect(frame.borderColor, null);
    });

    test('should create modern template', () {
      final frame = WindowFrame.modern();

      expect(frame.name, 'Modern');
      expect(frame.padding, const EdgeInsets.all(24));
      expect(frame.cornerRadius, 8.0);
      expect(frame.shadowBlur, 20.0);
      expect(frame.shadowOffset, const Offset(0, 4));
      expect(frame.shadowColor, const Color(0x26000000));
      expect(frame.backgroundColor, const Color(0xFFFFFFFF));
      expect(frame.borderWidth, 1.5);
      expect(frame.borderColor, const Color(0xFFE0E0E0));
    });

    test('should create minimal template', () {
      final frame = WindowFrame.minimal();

      expect(frame.name, 'Minimal');
      expect(frame.padding, const EdgeInsets.all(16));
      expect(frame.cornerRadius, 0.0);
      expect(frame.shadowBlur, 0.0);
      expect(frame.shadowOffset, Offset.zero);
      expect(frame.shadowColor, const Color(0x00000000));
      expect(frame.backgroundColor, null);
      expect(frame.borderWidth, 0.0);
      expect(frame.borderColor, null);
    });

    test('should support copyWith for customization', () {
      final original = WindowFrame.rounded();
      final modified = original.copyWith(
        name: 'Custom Rounded',
        padding: const EdgeInsets.all(50),
        cornerRadius: 20.0,
      );

      expect(modified.name, 'Custom Rounded');
      expect(modified.padding, const EdgeInsets.all(50));
      expect(modified.cornerRadius, 20.0);
      // Other properties should remain unchanged
      expect(modified.shadowBlur, original.shadowBlur);
      expect(modified.shadowOffset, original.shadowOffset);
      expect(modified.shadowColor, original.shadowColor);
      expect(modified.backgroundColor, original.backgroundColor);
      expect(modified.borderWidth, original.borderWidth);
      expect(modified.borderColor, original.borderColor);
    });

    test('should serialize to and from JSON', () {
      final original = WindowFrame(
        name: 'Test Frame',
        padding: const EdgeInsets.all(25),
        cornerRadius: 15.0,
        shadowBlur: 35.0,
        shadowOffset: const Offset(0, 5),
        shadowColor: const Color(0x40000000),
        backgroundColor: const Color(0xFFF0F0F0),
        borderWidth: 1.5,
        borderColor: const Color(0xFFCCCCCC),
      );

      final json = original.toJson();
      final restored = WindowFrame.fromJson(json);

      expect(restored.name, original.name);
      expect(restored.padding, original.padding);
      expect(restored.cornerRadius, original.cornerRadius);
      expect(restored.shadowBlur, original.shadowBlur);
      expect(restored.shadowOffset, original.shadowOffset);
      expect(restored.shadowColor, original.shadowColor);
      expect(restored.backgroundColor, original.backgroundColor);
      expect(restored.borderWidth, original.borderWidth);
      expect(restored.borderColor, original.borderColor);
    });

    test('should provide list of all templates', () {
      final templates = WindowFrame.templates;

      expect(templates.length, 4);
      expect(templates[0].name, 'None');
      expect(templates[1].name, 'Rounded');
      expect(templates[2].name, 'Modern');
      expect(templates[3].name, 'Minimal');
    });

    test('should support equality operator with identical instances', () {
      final frame = WindowFrame.rounded();

      expect(frame == frame, true);
    });

    test('should support equality operator with equal instances', () {
      final frame1 = WindowFrame(
        name: 'Test',
        padding: const EdgeInsets.all(10),
        cornerRadius: 5.0,
        shadowBlur: 15.0,
        shadowOffset: const Offset(0, 2),
        shadowColor: const Color(0x33000000),
        backgroundColor: const Color(0xFFFFFFFF),
        borderWidth: 1.0,
        borderColor: const Color(0xFF000000),
      );

      final frame2 = WindowFrame(
        name: 'Test',
        padding: const EdgeInsets.all(10),
        cornerRadius: 5.0,
        shadowBlur: 15.0,
        shadowOffset: const Offset(0, 2),
        shadowColor: const Color(0x33000000),
        backgroundColor: const Color(0xFFFFFFFF),
        borderWidth: 1.0,
        borderColor: const Color(0xFF000000),
      );

      expect(frame1 == frame2, true);
    });

    test('should support equality operator with different instances', () {
      final frame1 = WindowFrame.rounded();
      final frame2 = WindowFrame.modern();

      expect(frame1 == frame2, false);
    });

    test('should have consistent hashCode for equal instances', () {
      final frame1 = WindowFrame(
        name: 'Test',
        padding: const EdgeInsets.all(10),
        cornerRadius: 5.0,
        shadowBlur: 15.0,
        shadowOffset: const Offset(0, 2),
        shadowColor: const Color(0x33000000),
        backgroundColor: const Color(0xFFFFFFFF),
        borderWidth: 1.0,
        borderColor: const Color(0xFF000000),
      );

      final frame2 = WindowFrame(
        name: 'Test',
        padding: const EdgeInsets.all(10),
        cornerRadius: 5.0,
        shadowBlur: 15.0,
        shadowOffset: const Offset(0, 2),
        shadowColor: const Color(0x33000000),
        backgroundColor: const Color(0xFFFFFFFF),
        borderWidth: 1.0,
        borderColor: const Color(0xFF000000),
      );

      expect(frame1.hashCode == frame2.hashCode, true);
    });

    test('should have different hashCode for different instances', () {
      final frame1 = WindowFrame.rounded();
      final frame2 = WindowFrame.modern();

      expect(frame1.hashCode == frame2.hashCode, false);
    });

    test('should provide meaningful toString output', () {
      final frame = WindowFrame(
        name: 'Test',
        padding: const EdgeInsets.all(10),
        cornerRadius: 5.0,
        shadowBlur: 15.0,
        shadowOffset: const Offset(0, 2),
        shadowColor: const Color(0x33000000),
        backgroundColor: const Color(0xFFFFFFFF),
        borderWidth: 1.0,
        borderColor: const Color(0xFF000000),
      );

      final str = frame.toString();

      expect(str, contains('WindowFrame'));
      expect(str, contains('name: Test'));
      expect(str, contains('padding: EdgeInsets.all(10.0)'));
      expect(str, contains('cornerRadius: 5.0'));
      expect(str, contains('shadowBlur: 15.0'));
      expect(str, contains('shadowOffset: Offset(0.0, 2.0)'));
      expect(str, contains('borderWidth: 1.0'));
    });

    test('should serialize to JSON with null optional fields', () {
      final frame = WindowFrame(
        name: 'Test',
        padding: const EdgeInsets.all(10),
        cornerRadius: 5.0,
        shadowBlur: 15.0,
        shadowOffset: const Offset(0, 2),
        shadowColor: const Color(0x33000000),
        backgroundColor: null,
        borderWidth: 0.0,
        borderColor: null,
      );

      final json = frame.toJson();

      expect(json['name'], 'Test');
      expect(json['backgroundColor'], null);
      expect(json['borderColor'], null);
    });

    test('should deserialize from JSON with null optional fields', () {
      final json = {
        'name': 'Test',
        'padding': {
          'left': 10.0,
          'top': 10.0,
          'right': 10.0,
          'bottom': 10.0,
        },
        'cornerRadius': 5.0,
        'shadowBlur': 15.0,
        'shadowOffset': {
          'dx': 0.0,
          'dy': 2.0,
        },
        'shadowColor': 0x33000000,
        'backgroundColor': null,
        'borderWidth': 0.0,
        'borderColor': null,
      };

      final frame = WindowFrame.fromJson(json);

      expect(frame.name, 'Test');
      expect(frame.backgroundColor, null);
      expect(frame.borderColor, null);
    });

    test('inset defaults to 0 and round-trips through JSON', () {
      final frame = WindowFrame.rounded().copyWith(inset: 18.5);
      expect(WindowFrame.rounded().inset, 0);
      expect(frame.inset, 18.5);

      final reloaded = WindowFrame.fromJson(frame.toJson());
      expect(reloaded.inset, 18.5);
      expect(reloaded, frame);
    });

    test('inset is missing in legacy JSON → defaults to 0', () {
      // Older sidecars saved before the inset field shipped should
      // load cleanly with inset=0 rather than throwing.
      final json = WindowFrame.rounded().toJson();
      json.remove('inset');
      final reloaded = WindowFrame.fromJson(json);
      expect(reloaded.inset, 0);
    });
  });
}
