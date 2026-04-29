import Foundation
import CoreGraphics
import ScreenCaptureKit
import AppKit

struct RawWindow {
  let id: UInt32
  let title: String?
  let ownerName: String
  let ownerBundleId: String
  let frame: CGRect
  let isOnScreen: Bool
}

enum SourceCatalog {
  /// Bundle IDs whose windows are always system noise in a recording picker.
  /// Intentionally narrow: com.apple.finder is NOT excluded because Finder
  /// windows (desktop, folders) are legitimate record targets.
  static let excludedBundleIds: Set<String> = [
    "com.apple.dock",
    "com.apple.systemuiserver",
    "com.apple.controlcenter",
    "com.apple.notificationcenterui",
    "com.apple.WindowManager",
  ]

  static func applyStrictFilter(_ windows: [RawWindow]) -> [[String: Any]] {
    return windows.compactMap { w -> [String: Any]? in
      guard let title = w.title,
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      guard !excludedBundleIds.contains(w.ownerBundleId) else { return nil }
      guard w.frame.width >= 50, w.frame.height >= 50 else { return nil }
      return [
        "id": String(w.id),
        "title": title,
        "ownerName": w.ownerName,
        "x": Int(w.frame.origin.x),
        "y": Int(w.frame.origin.y),
        "width": Int(w.frame.size.width),
        "height": Int(w.frame.size.height),
        "isOnScreen": w.isOnScreen,
      ]
    }
  }

  /// Same dictionary projection as `applyStrictFilter` but without any drop
  /// rules. Both methods must stay in sync: adding a field to one requires
  /// adding it to the other.
  static func projectAll(_ windows: [RawWindow]) -> [[String: Any]] {
    return windows.map { w in
      [
        "id": String(w.id),
        "title": w.title ?? "",
        "ownerName": w.ownerName,
        "x": Int(w.frame.origin.x),
        "y": Int(w.frame.origin.y),
        "width": Int(w.frame.size.width),
        "height": Int(w.frame.size.height),
        "isOnScreen": w.isOnScreen,
      ]
    }
  }

  static func rawWindow(from w: SCWindow) -> RawWindow {
    return RawWindow(
      id: w.windowID,
      title: w.title,
      ownerName: w.owningApplication?.applicationName ?? "Unknown",
      ownerBundleId: w.owningApplication?.bundleIdentifier ?? "",
      frame: w.frame,
      isOnScreen: w.isOnScreen
    )
  }

  /// Calls `SCShareableContent` exactly once and returns method-channel-ready
  /// dictionaries for both windows and screens.
  static func listSources(strictFilter: Bool) async throws -> (windows: [[String: Any]], screens: [[String: Any]]) {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let raw = content.windows.map { rawWindow(from: $0) }
    let windows = strictFilter ? applyStrictFilter(raw) : projectAll(raw)
    let mainID = CGMainDisplayID()
    let screens = content.displays.map { display -> [String: Any] in
      let name: String
      if let nsScreen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
      }) {
        name = nsScreen.localizedName
      } else if display.displayID == mainID {
        name = "Main Display"
      } else {
        name = "Display \(display.displayID)"
      }
      return [
        "id": String(display.displayID),
        "name": name,
        "width": display.width,
        "height": display.height,
        "isPrimary": display.displayID == mainID,
      ]
    }
    return (windows, screens)
  }
}
