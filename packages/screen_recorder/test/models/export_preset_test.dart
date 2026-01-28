import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/export_preset.dart';

void main() {
  group('ExportPreset', () {
    test('should create preset with all properties', () {
      final preset = ExportPreset(
        name: 'Custom',
        width: 1920,
        height: 1080,
        fps: 30,
        quality: 0.85,
      );

      expect(preset.name, equals('Custom'));
      expect(preset.width, equals(1920));
      expect(preset.height, equals(1080));
      expect(preset.fps, equals(30));
      expect(preset.quality, equals(0.85));
    });

    test('should create 1080p 30fps preset', () {
      final preset = ExportPreset.hd1080p30();

      expect(preset.name, equals('1080p 30fps'));
      expect(preset.width, equals(1920));
      expect(preset.height, equals(1080));
      expect(preset.fps, equals(30));
      expect(preset.quality, equals(0.85));
    });

    test('should create 1080p 60fps preset', () {
      final preset = ExportPreset.hd1080p60();

      expect(preset.name, equals('1080p 60fps'));
      expect(preset.width, equals(1920));
      expect(preset.height, equals(1080));
      expect(preset.fps, equals(60));
      expect(preset.quality, equals(0.90));
    });

    test('should create 4K 30fps preset', () {
      final preset = ExportPreset.uhd4k30();

      expect(preset.name, equals('4K 30fps'));
      expect(preset.width, equals(3840));
      expect(preset.height, equals(2160));
      expect(preset.fps, equals(30));
      expect(preset.quality, equals(0.90));
    });

    test('should create 4K 60fps preset', () {
      final preset = ExportPreset.uhd4k60();

      expect(preset.name, equals('4K 60fps'));
      expect(preset.width, equals(3840));
      expect(preset.height, equals(2160));
      expect(preset.fps, equals(60));
      expect(preset.quality, equals(0.95));
    });

    test('should create web optimized preset', () {
      final preset = ExportPreset.webOptimized();

      expect(preset.name, equals('Web Optimized'));
      expect(preset.width, equals(1280));
      expect(preset.height, equals(720));
      expect(preset.fps, equals(30));
      expect(preset.quality, equals(0.75));
    });

    test('should serialize to and from JSON', () {
      final preset = ExportPreset(
        name: 'Test Preset',
        width: 1920,
        height: 1080,
        fps: 60,
        quality: 0.9,
      );

      final json = preset.toJson();
      expect(json['name'], equals('Test Preset'));
      expect(json['width'], equals(1920));
      expect(json['height'], equals(1080));
      expect(json['fps'], equals(60));
      expect(json['quality'], equals(0.9));

      final restored = ExportPreset.fromJson(json);
      expect(restored.name, equals(preset.name));
      expect(restored.width, equals(preset.width));
      expect(restored.height, equals(preset.height));
      expect(restored.fps, equals(preset.fps));
      expect(restored.quality, equals(preset.quality));
    });

    test('should provide all built-in presets', () {
      final presets = ExportPreset.presets;

      expect(presets.length, equals(5));
      expect(presets[0].name, equals('1080p 30fps'));
      expect(presets[1].name, equals('1080p 60fps'));
      expect(presets[2].name, equals('4K 30fps'));
      expect(presets[3].name, equals('4K 60fps'));
      expect(presets[4].name, equals('Web Optimized'));
    });
  });
}
