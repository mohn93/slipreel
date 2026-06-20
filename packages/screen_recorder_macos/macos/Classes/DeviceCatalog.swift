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

  /// Connected iOS devices. iPhones/iPads show up as `.external` (macOS 14+)
  /// or `.externalUnknown` once enabled + trusted + unlocked.
  static func connectedDevices() -> [[String: String]] {
    var types: [AVCaptureDevice.DeviceType] = []
    if #available(macOS 14.0, *) {
      types.append(.external)
    } else {
      types.append(.externalUnknown)
    }
    let discoveryMuxed = AVCaptureDevice.DiscoverySession(
      deviceTypes: types, mediaType: .muxed, position: .unspecified)
    let discoveryVideo = AVCaptureDevice.DiscoverySession(
      deviceTypes: types, mediaType: .video, position: .unspecified)
    var seen = Set<String>()
    let all = discoveryMuxed.devices + discoveryVideo.devices
    return all.compactMap { d in
      guard seen.insert(d.uniqueID).inserted else { return nil }
      let lower = d.localizedName.lowercased()
      let kind = lower.contains("ipad") ? "tablet" : "phone"
      return ["id": d.uniqueID, "name": d.localizedName, "kind": kind]
    }
  }
}
