import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/export_preset.dart';

void main() {
  group('ExportPreset', () {
    test('should create preset with all properties', () {
      const preset = ExportPreset(
        name: 'Custom',
        width: 1920,
        height: 1080,
        fps: 30,
        quality: 0.9,
      );

      expect(preset.name, 'Custom');
      expect(preset.width, 1920);
      expect(preset.height, 1080);
      expect(preset.fps, 30);
      expect(preset.quality, 0.9);
    });

    test('should create 1080p 30fps preset', () {
      final preset = ExportPreset.hd1080p30();

      expect(preset.name, '1080p 30fps');
      expect(preset.width, 1920);
      expect(preset.height, 1080);
      expect(preset.fps, 30);
      expect(preset.quality, 0.85);
    });

    test('should create 1080p 60fps preset', () {
      final preset = ExportPreset.hd1080p60();

      expect(preset.name, '1080p 60fps');
      expect(preset.width, 1920);
      expect(preset.height, 1080);
      expect(preset.fps, 60);
      expect(preset.quality, 0.9);
    });

    test('should create 4K 30fps preset', () {
      final preset = ExportPreset.uhd4k30();

      expect(preset.name, '4K 30fps');
      expect(preset.width, 3840);
      expect(preset.height, 2160);
      expect(preset.fps, 30);
      expect(preset.quality, 0.90);
    });

    test('should create 4K 60fps preset', () {
      final preset = ExportPreset.uhd4k60();

      expect(preset.name, '4K 60fps');
      expect(preset.width, 3840);
      expect(preset.height, 2160);
      expect(preset.fps, 60);
      expect(preset.quality, 0.95);
    });

    test('should create web optimized preset', () {
      final preset = ExportPreset.webOptimized();

      expect(preset.name, 'Web Optimized');
      expect(preset.width, 1280);
      expect(preset.height, 720);
      expect(preset.fps, 30);
      expect(preset.quality, 0.75);
    });

    test('should serialize to and from JSON', () {
      const preset = ExportPreset(
        name: 'Test',
        width: 1920,
        height: 1080,
        fps: 30,
        quality: 0.9,
      );

      final json = preset.toJson();
      final restored = ExportPreset.fromJson(json);

      expect(restored.name, preset.name);
      expect(restored.width, preset.width);
      expect(restored.height, preset.height);
      expect(restored.fps, preset.fps);
      expect(restored.quality, preset.quality);
    });

    test('should provide all built-in presets', () {
      final presets = ExportPreset.presets;

      expect(presets.length, 5);
      expect(presets[0].name, '1080p 30fps');
      expect(presets[1].name, '1080p 60fps');
      expect(presets[2].name, '4K 30fps');
      expect(presets[3].name, '4K 60fps');
      expect(presets[4].name, 'Web Optimized');
    });
  });
}
