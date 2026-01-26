/// Information about an audio input device
class AudioDeviceInfo {
  final String id;
  final String name;
  final AudioDeviceType type;

  const AudioDeviceInfo({
    required this.id,
    required this.name,
    required this.type,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
    };
  }

  factory AudioDeviceInfo.fromJson(Map<String, dynamic> json) {
    return AudioDeviceInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      type: AudioDeviceType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => AudioDeviceType.unknown,
      ),
    );
  }

  @override
  String toString() {
    return 'AudioDeviceInfo(id: $id, name: $name, type: $type)';
  }
}

enum AudioDeviceType {
  system,
  microphone,
  unknown,
}
