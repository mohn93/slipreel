// packages/screen_recorder_macos/macos/Classes/DeviceCatalog.swift
import AVFoundation
import CoreMediaIO

/// Enumerates USB-connected iOS devices (iPhone/iPad) as AVFoundation capture
/// devices. iOS devices are screen-capture DAL devices HIDDEN by default;
/// `enableScreenCaptureDevices()` flips the CoreMediaIO property QuickTime sets
/// so they become discoverable.
enum DeviceCatalog {
  /// Idempotent. Call once at plugin init, before discovery.
  static func enableScreenCaptureDevices() {
    var prop = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var allow: UInt32 = 1
    CMIOObjectSetPropertyData(
      CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil,
      UInt32(MemoryLayout<UInt32>.size), &allow)
  }

  /// Connected iOS SCREEN-capture devices. iPhones/iPads show up as `.external`
  /// (macOS 14+) or `.externalUnknown` once enabled + trusted + unlocked.
  ///
  /// We keep ONLY muxed devices — the iPhone screen device exposes a MUXED
  /// (audio+video) stream, whereas the Continuity Camera is a video-only
  /// `.continuityCamera`. Filtering to muxed (and excluding `.continuityCamera`)
  /// drops the camera so the picker lists screens only.
  static func connectedDevices() -> [[String: String]] {
    var types: [AVCaptureDevice.DeviceType] = [.externalUnknown]
    if #available(macOS 14.0, *) {
      types.append(.external)
    }
    let session = AVCaptureDevice.DiscoverySession(
      deviceTypes: types, mediaType: nil, position: .unspecified)
    var seen = Set<String>()
    var out: [[String: String]] = []
    for d in session.devices {
      guard seen.insert(d.uniqueID).inserted else { continue }
      // Keep only muxed screen devices; drop the video-only Continuity Camera.
      guard d.hasMediaType(.muxed) else { continue }
      if #available(macOS 14.0, *), d.deviceType == .continuityCamera { continue }
      let kind = d.localizedName.lowercased().contains("ipad") ? "tablet" : "phone"
      out.append([
        "id": d.uniqueID,
        "name": d.localizedName,
        "kind": kind,
      ])
    }
    return out
  }
}
