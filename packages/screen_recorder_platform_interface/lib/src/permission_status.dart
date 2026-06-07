// packages/screen_recorder_platform_interface/lib/src/permission_status.dart

/// The permission kinds Slipreel cares about.
enum PermissionKind { screenRecording, microphone, accessibility, camera }

/// Status of a single permission kind, in a shape that maps cleanly to
/// macOS's `AVAuthorizationStatus` + ScreenCaptureKit + AX states, and
/// degrades to `unsupported` everywhere else.
enum PermissionStatus {
  granted('granted'),
  denied('denied'),
  notDetermined('notDetermined'),
  restricted('restricted'),
  unsupported('unsupported');

  const PermissionStatus(this.wire);

  /// The string used on the method-channel wire.
  final String wire;
}

/// Decodes wire strings sent by native side. Unknown / null values
/// fall back to [PermissionStatus.notDetermined] — safer than throwing
/// because an unrecognised status should let the user attempt to Grant
/// rather than soft-lock the UI.
class PermissionStatusCodec {
  const PermissionStatusCodec._();

  static PermissionStatus fromWire(String? wire) {
    if (wire == null) return PermissionStatus.notDetermined;
    for (final s in PermissionStatus.values) {
      if (s.wire == wire) return s;
    }
    return PermissionStatus.notDetermined;
  }
}
