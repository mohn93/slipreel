/// Information about an audio input device
class AudioDeviceInfo {
  final String id;
  final String name;
  final AudioDeviceType type;
  final bool isDefault;

  const AudioDeviceInfo({
    required this.id,
    required this.name,
    required this.type,
    this.isDefault = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'isDefault': isDefault,
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
      isDefault: json['isDefault'] as bool? ?? false,
    );
  }

  @override
  String toString() {
    return 'AudioDeviceInfo(id: $id, name: $name, type: $type, isDefault: $isDefault)';
  }
}

enum AudioDeviceType {
  system,
  microphone,
  unknown,
}
