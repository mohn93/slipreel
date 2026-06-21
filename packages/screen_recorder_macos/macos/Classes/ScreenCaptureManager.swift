import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreVideo

/// Manages screen capture using ScreenCaptureKit framework
class ScreenCaptureManager: NSObject {
  // MARK: - Properties

  private var stream: SCStream?
  private var streamOutput: ScreenCaptureStreamOutput?
  private var streamConfiguration: SCStreamConfiguration?
  private var contentFilter: SCContentFilter?
  private var isCapturing = false

  // Callback for frame data
  var onFrameReceived: ((CMSampleBuffer) -> Void)?
  var onError: ((Error) -> Void)?

  // Frame throttling
  private var lastFrameTime: CFAbsoluteTime = 0
  private var minFrameInterval: CFAbsoluteTime = 1.0 / 60.0  // Max 60fps

  // MARK: - Permission Handling

  /// Check if screen recording permission is granted.
  ///
  /// PASSIVE status check ONLY — must not trigger the consent dialog.
  /// `CGPreflightScreenCaptureAccess()` reports the current Screen Recording
  /// authorization *without* prompting. The previous implementation called
  /// `SCShareableContent`, which can re-pop the Screen Recording prompt even
  /// when access is already granted — and because the Dart app re-probes all
  /// permissions on every app focus (`refreshAll()` on resume), that surfaced
  /// as a Screen Recording dialog reappearing on every window focus.
  ///
  /// The actual consent prompt is still triggered where it belongs — by
  /// `requestPermission()` and by a real capture attempt — not by this check.
  /// (Available macOS 10.15+; the app's deployment target is 13.0.)
  func checkPermission() async -> Bool {
    return CGPreflightScreenCaptureAccess()
  }

  /// Request screen recording permission
  /// Note: On macOS, this requires user to grant permission in System Preferences
  func requestPermission() async throws -> Bool {
    // Attempting to get shareable content will trigger permission prompt
    do {
      _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      return true
    } catch {
      throw ScreenCaptureError.permissionDenied
    }
  }

  // MARK: - Content Discovery

  /// Get all available displays/screens
  func getAvailableDisplays() async throws -> [[String: Any]] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    let mainDisplayID = CGMainDisplayID()
    return content.displays.map { display in
      return [
        "id": String(display.displayID),
        "name": display.displayID == mainDisplayID ? "Main Display" : "Display \(display.displayID)",
        "width": Int(display.width),
        "height": Int(display.height),
        "isPrimary": display.displayID == mainDisplayID
      ]
    }
  }

  /// Get all available windows.
  ///
  /// IMPORTANT: the `x`/`y`/`width`/`height` values returned here are in
  /// display POINTS (`SCWindow.frame` is point-based). The actual capture
  /// dimensions are POINTS × `backingScaleFactor` PIXELS on Retina
  /// displays — see `captureDimensions(sourceId:isWindow:)` for the
  /// pixel-accurate values used by the encoder. Don't size buffers off
  /// the window bounds directly.
  func getAvailableWindows() async throws -> [[String: Any]] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    return content.windows.compactMap { window -> [String: Any]? in
      // Filter out windows without title or that are minimized
      guard let title = window.title,
            !title.isEmpty,
            window.isOnScreen else {
        return nil
      }

      return [
        "id": String(window.windowID),
        "title": title,
        "ownerName": window.owningApplication?.applicationName ?? "Unknown",
        "x": Int(window.frame.origin.x),
        "y": Int(window.frame.origin.y),
        "width": Int(window.frame.size.width),
        "height": Int(window.frame.size.height),
        "isOnScreen": window.isOnScreen
      ]
    }
  }

  // MARK: - Dimension Query

  /// Compute the actual pixel dimensions that would be used for capture,
  /// matching what SCStream produces for the given source. Window dimensions
  /// account for Retina backing scale; display dimensions are already in pixels.
  func captureDimensions(sourceId: String, isWindow: Bool) async throws -> (width: Int, height: Int) {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    if isWindow {
      guard let windowID = UInt32(sourceId),
            let window = content.windows.first(where: { $0.windowID == windowID }) else {
        throw ScreenCaptureError.invalidSourceId
      }
      let scale = NSScreen.main?.backingScaleFactor ?? 1.0
      return (Int(window.frame.width * scale), Int(window.frame.height * scale))
    } else {
      guard let displayID = UInt32(sourceId),
            let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw ScreenCaptureError.invalidSourceId
      }
      return (display.width, display.height)
    }
  }

  /// Compute the actual pixel dimensions for a region capture.
  func captureDimensions(region: RegionSelection) -> (width: Int, height: Int) {
    return (region.widthPx, region.heightPx)
  }

  // MARK: - Recording Control

  func startCapture(
    sourceId: String,
    fps: Int,
    isWindow: Bool,
    region: RegionSelection? = nil,
    showCursor: Bool = false
  ) async throws {
    guard !isCapturing else {
      throw ScreenCaptureError.alreadyCapturing
    }

    // Get shareable content
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    // Configure stream
    let config = SCStreamConfiguration()
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = showCursor
    config.queueDepth = 5

    if let region = region {
      // Region path: full-display filter + sourceRect crop.
      guard let display = content.displays.first(where: { $0.displayID == region.displayId }) else {
        throw ScreenCaptureError.invalidSourceId
      }
      contentFilter = SCContentFilter(display: display, excludingWindows: [])
      // Resolve the backing scale via NSScreen (matching display.id) instead
      // of `display.width / display.frame.width` — the latter has returned
      // wrong values on some macOS versions (SCDisplay.frame coming back as
      // pixels rather than points), which made sourceRect (documented as
      // points) end up as a 1:1 pixel rect that SCStream apparently ignored.
      let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == region.displayId
      })
      let backing = screen?.backingScaleFactor ?? 2.0
      config.sourceRect = CGRect(
        x: CGFloat(region.x) / backing,
        y: CGFloat(region.y) / backing,
        width: CGFloat(region.widthPx) / backing,
        height: CGFloat(region.heightPx) / backing
      )
      config.width = region.widthPx
      config.height = region.heightPx
    } else if isWindow {
      guard let windowID = UInt32(sourceId),
            let window = content.windows.first(where: { $0.windowID == windowID }) else {
        throw ScreenCaptureError.invalidSourceId
      }
      contentFilter = SCContentFilter(desktopIndependentWindow: window)
      let scale = NSScreen.main?.backingScaleFactor ?? 1.0
      config.width = Int(window.frame.width * scale)
      config.height = Int(window.frame.height * scale)
    } else {
      guard let displayID = UInt32(sourceId),
            let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw ScreenCaptureError.invalidSourceId
      }
      let excludedApps = content.applications.filter { app in
        app.bundleIdentifier == "com.apple.finder" ||
        app.bundleIdentifier == "com.apple.dock"
      }
      contentFilter = SCContentFilter(
        display: display,
        excludingApplications: excludedApps,
        exceptingWindows: []
      )
      config.width = display.width
      config.height = display.height
    }

    // SCStream source coords are in display points, but config.width/height
    // are in pixels. On a Retina display the implicit mapping is 1 source
    // point → 1 dest pixel, so the content ends up rendered in only the
    // top-left quadrant of the framebuffer (rest black). scalesToFit=true
    // scales the source area to fill the configured pixel buffer. We also
    // set destinationRect explicitly so the source fills the full buffer
    // even on macOS versions where the default destinationRect isn't the
    // whole buffer when sourceRect is set.
    //
    // IMPORTANT: assign these AFTER sourceRect/width/height. On some macOS
    // versions, setting sourceRect appears to reset scalesToFit when it's
    // assigned earlier in the same block.
    config.scalesToFit = true
    config.destinationRect = CGRect(x: 0, y: 0, width: config.width, height: config.height)

    streamConfiguration = config

    // Create and start stream
    guard let filter = contentFilter else {
      throw ScreenCaptureError.configurationFailed
    }

    stream = SCStream(filter: filter, configuration: config, delegate: self)

    // Add stream output with throttling (max 60fps)
    let output = ScreenCaptureStreamOutput(
      minFrameInterval: 1.0 / 60.0,
      onFrameReceived: { [weak self] sampleBuffer in
        self?.onFrameReceived?(sampleBuffer)
      }
    )
    self.streamOutput = output

    try stream?.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

    // Start capture
    try await stream?.startCapture()

    isCapturing = true
  }

  /// Stop capturing
  func stopCapture() async throws {
    guard isCapturing else {
      return
    }

    try await stream?.stopCapture()
    stream = nil
    streamOutput = nil
    contentFilter = nil
    streamConfiguration = nil
    isCapturing = false
  }

  /// Check if currently capturing
  func isCaptureActive() -> Bool {
    return isCapturing
  }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureManager: SCStreamDelegate {
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    isCapturing = false
    onError?(error)
  }
}

// MARK: - Stream Output Handler

private class ScreenCaptureStreamOutput: NSObject, SCStreamOutput {
  let onFrameReceived: (CMSampleBuffer) -> Void
  var lastFrameTime: CFAbsoluteTime = 0
  let minFrameInterval: CFAbsoluteTime

  init(minFrameInterval: CFAbsoluteTime, onFrameReceived: @escaping (CMSampleBuffer) -> Void) {
    self.minFrameInterval = minFrameInterval
    self.onFrameReceived = onFrameReceived
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    // Only process screen output
    guard type == .screen else { return }

    // Verify buffer is valid
    guard sampleBuffer.isValid else { return }

    // Throttling: Check if enough time has passed since last frame
    let currentTime = CFAbsoluteTimeGetCurrent()
    guard currentTime - lastFrameTime >= minFrameInterval else {
      return // Drop frame to prevent overwhelming Flutter
    }
    lastFrameTime = currentTime

    // Call the frame callback
    onFrameReceived(sampleBuffer)
  }
}

// MARK: - Error Types

enum ScreenCaptureError: LocalizedError {
  case permissionDenied
  case invalidSourceId
  case configurationFailed
  case alreadyCapturing
  case notCapturing

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      return "Screen recording permission denied. Please grant permission in System Preferences > Privacy & Security > Screen Recording."
    case .invalidSourceId:
      return "Invalid screen or window ID provided."
    case .configurationFailed:
      return "Failed to configure screen capture stream."
    case .alreadyCapturing:
      return "Screen capture is already in progress."
    case .notCapturing:
      return "No screen capture session is active."
    }
  }
}
