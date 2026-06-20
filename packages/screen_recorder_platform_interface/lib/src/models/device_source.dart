// packages/screen_recorder_platform_interface/lib/src/models/device_source.dart

/// A connected external recordable device (iPhone/iPad over USB).
enum DeviceKind { phone, tablet }

class DeviceSource {
  const DeviceSource({required this.id, required this.name, required this.kind});

  /// Stable AVFoundation uniqueID of the capture device.
  final String id;

  /// Human label, e.g. "Mohanned's iPhone".
  final String name;

  final DeviceKind kind;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind == DeviceKind.tablet ? 'tablet' : 'phone',
      };

  factory DeviceSource.fromJson(Map<String, dynamic> json) => DeviceSource(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: (json['kind'] as String?) == 'tablet'
            ? DeviceKind.tablet
            : DeviceKind.phone,
      );

  @override
  bool operator ==(Object other) =>
      other is DeviceSource &&
      other.id == id &&
      other.name == name &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, name, kind);
}
