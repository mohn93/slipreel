import 'package:slipreel_engine/models/export_settings.dart';

/// Frame rate at which [compressionBitrate]'s table values were tuned.
/// `effectiveBitrateKbps` scales linearly off this baseline so that
/// e.g. choosing 60fps actually doubles the bits/sec budget — without
/// this scaling, h264 has half as many bits per frame at 60fps and the
/// "Studio" / "Web" / etc. tier descriptions stop holding their promised
/// quality. 30fps is the natural baseline because it's the most common
/// recording rate.
const int kBaselineFrameRate = 30;

int compressionBitrate(ExportResolution resolution, CompressionTier tier) {
  return switch ((resolution, tier)) {
    (ExportResolution.r720p, CompressionTier.studio) => 8000,
    (ExportResolution.r720p, CompressionTier.socialMedia) => 5000,
    (ExportResolution.r720p, CompressionTier.web) => 3000,
    (ExportResolution.r720p, CompressionTier.webLow) => 1500,
    (ExportResolution.r1080p, CompressionTier.studio) => 16000,
    (ExportResolution.r1080p, CompressionTier.socialMedia) => 10000,
    (ExportResolution.r1080p, CompressionTier.web) => 6000,
    (ExportResolution.r1080p, CompressionTier.webLow) => 3000,
    (ExportResolution.r4k, CompressionTier.studio) => 50000,
    (ExportResolution.r4k, CompressionTier.socialMedia) => 32000,
    (ExportResolution.r4k, CompressionTier.web) => 20000,
    (ExportResolution.r4k, CompressionTier.webLow) => 10000,
  };
}

/// Bitrate the encoder should actually target for [frameRate], scaled
/// linearly off the [kBaselineFrameRate] table value. Always at least
/// 1 kbps to avoid degenerate outputs at unrealistically low rates.
int effectiveBitrateKbps(
  ExportResolution resolution,
  CompressionTier tier,
  int frameRate,
) {
  final base = compressionBitrate(resolution, tier);
  final scaled = (base * frameRate / kBaselineFrameRate).round();
  return scaled < 1 ? 1 : scaled;
}

class GifPaletteSettings {
  const GifPaletteSettings({required this.maxColors, required this.dither});
  final int maxColors;
  final String dither;
}

GifPaletteSettings gifPaletteSettings(CompressionTier tier) {
  return switch (tier) {
    CompressionTier.studio => const GifPaletteSettings(
      maxColors: 256,
      dither: 'sierra2_4a',
    ),
    CompressionTier.socialMedia => const GifPaletteSettings(
      maxColors: 192,
      dither: 'sierra2_4a',
    ),
    CompressionTier.web => const GifPaletteSettings(
      maxColors: 128,
      dither: 'bayer:bayer_scale=3',
    ),
    CompressionTier.webLow => const GifPaletteSettings(
      maxColors: 64,
      dither: 'none',
    ),
  };
}
