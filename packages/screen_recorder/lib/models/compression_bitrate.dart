import 'package:screen_recorder/models/export_settings.dart';

int compressionBitrate(ExportResolution resolution, CompressionTier tier) {
  return _bitrateTable[(resolution, tier)]!;
}

const _bitrateTable = <(ExportResolution, CompressionTier), int>{
  (ExportResolution.r720p, CompressionTier.studio): 8000,
  (ExportResolution.r720p, CompressionTier.socialMedia): 5000,
  (ExportResolution.r720p, CompressionTier.web): 3000,
  (ExportResolution.r720p, CompressionTier.webLow): 1500,
  (ExportResolution.r1080p, CompressionTier.studio): 16000,
  (ExportResolution.r1080p, CompressionTier.socialMedia): 10000,
  (ExportResolution.r1080p, CompressionTier.web): 6000,
  (ExportResolution.r1080p, CompressionTier.webLow): 3000,
  (ExportResolution.r4k, CompressionTier.studio): 50000,
  (ExportResolution.r4k, CompressionTier.socialMedia): 32000,
  (ExportResolution.r4k, CompressionTier.web): 20000,
  (ExportResolution.r4k, CompressionTier.webLow): 10000,
};

class GifPaletteSettings {
  const GifPaletteSettings({required this.maxColors, required this.dither});
  final int maxColors;
  final String dither;
}

GifPaletteSettings gifPaletteSettings(CompressionTier tier) {
  return switch (tier) {
    CompressionTier.studio =>
      const GifPaletteSettings(maxColors: 256, dither: 'sierra2_4a'),
    CompressionTier.socialMedia =>
      const GifPaletteSettings(maxColors: 192, dither: 'sierra2_4a'),
    CompressionTier.web =>
      const GifPaletteSettings(maxColors: 128, dither: 'bayer:bayer_scale=3'),
    CompressionTier.webLow =>
      const GifPaletteSettings(maxColors: 64, dither: 'none'),
  };
}
