import 'dart:typed_data';

/// Represents audio sample data
class AudioData {
  final Uint8List data;
  final int sampleRate;
  final int channels;
  final int timestampMicros;

  const AudioData({
    required this.data,
    required this.sampleRate,
    required this.channels,
    required this.timestampMicros,
  })  : assert(sampleRate > 0, 'sampleRate must be positive'),
        assert(channels > 0, 'channels must be positive'),
        assert(timestampMicros >= 0, 'timestampMicros cannot be negative');

  Map<String, dynamic> toJson() {
    return {
      'data': data,
      'sampleRate': sampleRate,
      'channels': channels,
      'timestampMicros': timestampMicros,
    };
  }

  factory AudioData.fromJson(Map<String, dynamic> json) {
    return AudioData(
      data: json['data'] as Uint8List,
      sampleRate: json['sampleRate'] as int,
      channels: json['channels'] as int,
      timestampMicros: json['timestampMicros'] as int,
    );
  }

  @override
  String toString() {
    return 'AudioData(sampleRate: $sampleRate, channels: $channels, timestamp: $timestampMicros, size: ${data.length} bytes)';
  }
}
