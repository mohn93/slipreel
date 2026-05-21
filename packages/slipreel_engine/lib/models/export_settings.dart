import 'package:flutter/painting.dart';

enum ExportFormat { mp4, gif }

enum ExportResolution { r720p, r1080p, r4k }

enum CompressionTier { studio, socialMedia, web, webLow }

enum ExportDestination { file, clipboard, shareableLink }

const kFrameRateOptions = <int>[60, 50, 30, 25, 24, 20, 10];

class ExportSettings {
  const ExportSettings({
    required this.format,
    required this.resolution,
    required this.compression,
    required this.frameRate,
    required this.destination,
    this.title,
    this.isPrivate = false,
  });

  final ExportFormat format;
  final ExportResolution resolution;
  final CompressionTier compression;
  final int frameRate;
  final ExportDestination destination;
  final String? title;
  final bool isPrivate;

  factory ExportSettings.defaults() => const ExportSettings(
    format: ExportFormat.mp4,
    resolution: ExportResolution.r1080p,
    compression: CompressionTier.web,
    frameRate: 30,
    destination: ExportDestination.file,
  );

  ExportSettings copyWith({
    ExportFormat? format,
    ExportResolution? resolution,
    CompressionTier? compression,
    int? frameRate,
    ExportDestination? destination,
    String? title,

    /// Pass `true` to set `title` to null. Distinguishes "leave alone"
    /// (the default) from "explicitly clear" — `copyWith(title: null)`
    /// alone can't, because `null` is the param-not-supplied default.
    bool clearTitle = false,
    bool? isPrivate,
  }) {
    return ExportSettings(
      format: format ?? this.format,
      resolution: resolution ?? this.resolution,
      compression: compression ?? this.compression,
      frameRate: frameRate ?? this.frameRate,
      destination: destination ?? this.destination,
      title: clearTitle ? null : (title ?? this.title),
      isPrivate: isPrivate ?? this.isPrivate,
    );
  }

  Map<String, dynamic> toJson() => {
    'format': format.name,
    'resolution': resolution.name,
    'compression': compression.name,
    'frameRate': frameRate,
    'destination': destination.name,
    if (title != null) 'title': title,
    'isPrivate': isPrivate,
  };

  factory ExportSettings.fromJson(Map<String, dynamic> json) {
    final formatStr = json['format'] as String?;
    if (formatStr == null) {
      throw FormatException('ExportSettings: missing required field "format"');
    }
    final format = _decodeEnum<ExportFormat>(
      formatStr,
      ExportFormat.values,
      'format',
    );

    final resolutionStr = json['resolution'] as String?;
    if (resolutionStr == null) {
      throw FormatException(
        'ExportSettings: missing required field "resolution"',
      );
    }
    final resolution = _decodeEnum<ExportResolution>(
      resolutionStr,
      ExportResolution.values,
      'resolution',
    );

    final compressionStr = json['compression'] as String?;
    if (compressionStr == null) {
      throw FormatException(
        'ExportSettings: missing required field "compression"',
      );
    }
    final compression = _decodeEnum<CompressionTier>(
      compressionStr,
      CompressionTier.values,
      'compression',
    );

    final frameRate = json['frameRate'] as int?;
    if (frameRate == null) {
      throw FormatException(
        'ExportSettings: missing required field "frameRate"',
      );
    }

    final destinationStr = json['destination'] as String?;
    if (destinationStr == null) {
      throw FormatException(
        'ExportSettings: missing required field "destination"',
      );
    }
    final destination = _decodeEnum<ExportDestination>(
      destinationStr,
      ExportDestination.values,
      'destination',
    );

    return ExportSettings(
      format: format,
      resolution: resolution,
      compression: compression,
      frameRate: frameRate,
      destination: destination,
      title: json['title'] as String?,
      isPrivate: (json['isPrivate'] as bool?) ?? false,
    );
  }

  static T _decodeEnum<T extends Enum>(
    String name,
    List<T> values,
    String fieldName,
  ) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    throw FormatException(
      'ExportSettings: invalid value "$name" for field "$fieldName"',
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is ExportSettings &&
        other.format == format &&
        other.resolution == resolution &&
        other.compression == compression &&
        other.frameRate == frameRate &&
        other.destination == destination &&
        other.title == title &&
        other.isPrivate == isPrivate;
  }

  @override
  int get hashCode => Object.hash(
    format,
    resolution,
    compression,
    frameRate,
    destination,
    title,
    isPrivate,
  );

  @override
  String toString() =>
      'ExportSettings(format: $format, resolution: $resolution, '
      'compression: $compression, frameRate: $frameRate, '
      'destination: $destination, title: $title, isPrivate: $isPrivate)';
}

extension ExportResolutionDimensions on ExportResolution {
  int get targetHeight {
    return switch (this) {
      ExportResolution.r720p => 720,
      ExportResolution.r1080p => 1080,
      ExportResolution.r4k => 2160,
    };
  }

  Size dimensionsFor(Size sourceVideo) {
    final srcWidth = sourceVideo.width;
    final srcHeight = sourceVideo.height;

    final targetW = (targetHeight * srcWidth / srcHeight).round();

    // yuv420p (h264) requires both dimensions even
    final width = targetW.isEven ? targetW : targetW + 1;

    return Size(width.toDouble(), targetHeight.toDouble());
  }
}
