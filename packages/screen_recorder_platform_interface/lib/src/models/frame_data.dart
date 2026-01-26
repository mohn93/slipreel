import 'dart:typed_data';

/// Represents a single video frame
class FrameData {
  final Uint8List data;
  final int width;
  final int height;
  final int timestampMicros;
  final PixelFormat format;

  const FrameData({
    required this.data,
    required this.width,
    required this.height,
    required this.timestampMicros,
    this.format = PixelFormat.bgra,
  });

  Map<String, dynamic> toJson() {
    return {
      'data': data,
      'width': width,
      'height': height,
      'timestampMicros': timestampMicros,
      'format': format.name,
    };
  }

  factory FrameData.fromJson(Map<String, dynamic> json) {
    return FrameData(
      data: json['data'] as Uint8List,
      width: json['width'] as int,
      height: json['height'] as int,
      timestampMicros: json['timestampMicros'] as int,
      format: PixelFormat.values.firstWhere(
        (e) => e.name == json['format'],
        orElse: () => PixelFormat.bgra,
      ),
    );
  }

  @override
  String toString() {
    return 'FrameData(size: ${width}x$height, timestamp: $timestampMicros, format: $format)';
  }
}

enum PixelFormat {
  bgra,
  rgba,
  yuv420,
}
