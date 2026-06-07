/// A chosen camera (webcam) device. `null` (absence of this config) means
/// "don't record camera". Capture-time only — look/placement is an editor
/// concern handled in Plan 2.
class CameraConfig {
  /// Stable AVCaptureDevice uniqueID, used to re-resolve the device at capture.
  final String deviceUid;

  /// Human-readable device name, shown on the bar's camera control.
  final String deviceLabel;

  const CameraConfig({required this.deviceUid, required this.deviceLabel});

  Map<String, dynamic> toJson() => {
        'deviceUid': deviceUid,
        'deviceLabel': deviceLabel,
      };

  factory CameraConfig.fromJson(Map<String, dynamic> json) => CameraConfig(
        deviceUid: json['deviceUid'] as String,
        deviceLabel: json['deviceLabel'] as String,
      );

  CameraConfig copyWith({String? deviceUid, String? deviceLabel}) =>
      CameraConfig(
        deviceUid: deviceUid ?? this.deviceUid,
        deviceLabel: deviceLabel ?? this.deviceLabel,
      );

  @override
  bool operator ==(Object other) =>
      other is CameraConfig &&
      other.deviceUid == deviceUid &&
      other.deviceLabel == deviceLabel;

  @override
  int get hashCode => Object.hash(deviceUid, deviceLabel);

  @override
  String toString() => 'CameraConfig($deviceLabel)';
}

/// Result of the native camera menu. [cancelled] true means the user dismissed
/// it (no change). When not cancelled, [config] is the new selection, or null
/// for "Don't record camera".
class CameraMenuResult {
  final bool cancelled;
  final CameraConfig? config;

  const CameraMenuResult({required this.cancelled, this.config});

  factory CameraMenuResult.fromJson(Map<String, dynamic> json) {
    final c = json['config'];
    return CameraMenuResult(
      cancelled: json['cancelled'] as bool? ?? false,
      config: c == null
          ? null
          : CameraConfig.fromJson(Map<String, dynamic>.from(c as Map)),
    );
  }
}
