import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/compression_bitrate.dart';
import 'package:screen_recorder/models/export_settings.dart';

void main() {
  group('compressionBitrate', () {
    test('720p + Studio = 8000 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r720p, CompressionTier.studio),
        8000,
      );
    });

    test('720p + Social Media = 5000 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r720p, CompressionTier.socialMedia),
        5000,
      );
    });

    test('720p + Web = 3000 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r720p, CompressionTier.web),
        3000,
      );
    });

    test('720p + Web (Low) = 1500 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r720p, CompressionTier.webLow),
        1500,
      );
    });

    test('1080p + Studio = 16000 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r1080p, CompressionTier.studio),
        16000,
      );
    });

    test('1080p + Social Media = 10000 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r1080p, CompressionTier.socialMedia),
        10000,
      );
    });

    test('1080p + Web = 6000 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r1080p, CompressionTier.web),
        6000,
      );
    });

    test('1080p + Web (Low) = 3000 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r1080p, CompressionTier.webLow),
        3000,
      );
    });

    test('4K + Studio = 50000 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r4k, CompressionTier.studio),
        50000,
      );
    });

    test('4K + Social Media = 32000 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r4k, CompressionTier.socialMedia),
        32000,
      );
    });

    test('4K + Web = 20000 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r4k, CompressionTier.web),
        20000,
      );
    });

    test('4K + Web (Low) = 10000 kbps', () {
      expect(
        compressionBitrate(ExportResolution.r4k, CompressionTier.webLow),
        10000,
      );
    });
  });

  group('gifPaletteSettings', () {
    test('Studio: 256 colors, sierra2_4a dither', () {
      final settings = gifPaletteSettings(CompressionTier.studio);
      expect(settings.maxColors, 256);
      expect(settings.dither, 'sierra2_4a');
    });

    test('Social Media: 192 colors, sierra2_4a dither', () {
      final settings = gifPaletteSettings(CompressionTier.socialMedia);
      expect(settings.maxColors, 192);
      expect(settings.dither, 'sierra2_4a');
    });

    test('Web: 128 colors, bayer:bayer_scale=3 dither', () {
      final settings = gifPaletteSettings(CompressionTier.web);
      expect(settings.maxColors, 128);
      expect(settings.dither, 'bayer:bayer_scale=3');
    });

    test('Web (Low): 64 colors, none dither', () {
      final settings = gifPaletteSettings(CompressionTier.webLow);
      expect(settings.maxColors, 64);
      expect(settings.dither, 'none');
    });
  });

  group('effectiveBitrateKbps', () {
    test('returns the table value at the baseline rate (30fps)', () {
      expect(
        effectiveBitrateKbps(
            ExportResolution.r1080p, CompressionTier.web, 30),
        6000,
      );
    });

    test('60fps doubles the bitrate vs 30fps', () {
      expect(
        effectiveBitrateKbps(
            ExportResolution.r1080p, CompressionTier.web, 60),
        12000,
      );
    });

    test('15fps halves the bitrate vs 30fps', () {
      expect(
        effectiveBitrateKbps(
            ExportResolution.r1080p, CompressionTier.web, 15),
        3000,
      );
    });

    test('clamps to ≥ 1 kbps for unrealistically low rates', () {
      expect(
        effectiveBitrateKbps(
            ExportResolution.r720p, CompressionTier.webLow, 0),
        1,
      );
    });
  });
}
