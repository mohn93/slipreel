/// Model for export presets with resolution, framerate, and quality settings.
class ExportPreset {
  /// Display name for the preset
  final String name;

  /// Output width in pixels
  final int width;

  /// Output height in pixels
  final int height;

  /// Frames per second
  final int fps;

  /// Quality factor from 0.0 (lowest) to 1.0 (highest)
  /// Used for future FFmpeg CRF mapping
  final double quality;

  const ExportPreset({
    required this.name,
    required this.width,
    required this.height,
    required this.fps,
    required this.quality,
  });

  /// 1080p at 30 fps with high quality (0.85)
  factory ExportPreset.hd1080p30() {
    return const ExportPreset(
      name: '1080p 30fps',
      width: 1920,
      height: 1080,
      fps: 30,
      quality: 0.85,
    );
  }

  /// 1080p at 60 fps with very high quality (0.90)
  factory ExportPreset.hd1080p60() {
    return const ExportPreset(
      name: '1080p 60fps',
      width: 1920,
      height: 1080,
      fps: 60,
      quality: 0.90,
    );
  }

  /// 4K at 30 fps with very high quality (0.90)
  factory ExportPreset.uhd4k30() {
    return const ExportPreset(
      name: '4K 30fps',
      width: 3840,
      height: 2160,
      fps: 30,
      quality: 0.90,
    );
  }

  /// 4K at 60 fps with maximum quality (0.95)
  factory ExportPreset.uhd4k60() {
    return const ExportPreset(
      name: '4K 60fps',
      width: 3840,
      height: 2160,
      fps: 60,
      quality: 0.95,
    );
  }

  /// 720p at 30 fps optimized for web (0.75 quality)
  factory ExportPreset.webOptimized() {
    return const ExportPreset(
      name: 'Web Optimized',
      width: 1280,
      height: 720,
      fps: 30,
      quality: 0.75,
    );
  }

  /// List of all built-in presets
  static List<ExportPreset> get presets => [
        ExportPreset.hd1080p30(),
        ExportPreset.hd1080p60(),
        ExportPreset.uhd4k30(),
        ExportPreset.uhd4k60(),
        ExportPreset.webOptimized(),
      ];

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'width': width,
      'height': height,
      'fps': fps,
      'quality': quality,
    };
  }

  /// Create from JSON
  factory ExportPreset.fromJson(Map<String, dynamic> json) {
    return ExportPreset(
      name: json['name'] as String,
      width: json['width'] as int,
      height: json['height'] as int,
      fps: json['fps'] as int,
      quality: json['quality'] as double,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is ExportPreset &&
        other.name == name &&
        other.width == width &&
        other.height == height &&
        other.fps == fps &&
        other.quality == quality;
  }

  @override
  int get hashCode {
    return Object.hash(name, width, height, fps, quality);
  }

  @override
  String toString() {
    return 'ExportPreset(name: $name, width: $width, height: $height, fps: $fps, quality: $quality)';
  }
}
