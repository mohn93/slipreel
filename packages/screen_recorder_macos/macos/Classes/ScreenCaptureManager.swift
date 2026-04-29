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

  /// Check if screen recording permission is granted
  func checkPermission() async -> Bool {
    if #available(macOS 13.0, *) {
      // For macOS 13+, we can check by attempting to get shareable content
      do {
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return true
      } catch {
        return false
      }
    } else {
      // For earlier versions, assume permission is granted
      // (ScreenCaptureKit requires macOS 12.3+)
      return true
    }
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

  /// Get all available windows
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
    showCursor: Bool = true
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
    config.scalesToFit = false
    config.showsCursor = showCursor
    config.queueDepth = 5

    if let region = region {
      // Region path: full-display filter + sourceRect crop.
      guard let display = content.displays.first(where: { $0.displayID == region.displayId }) else {
        throw ScreenCaptureError.invalidSourceId
      }
      contentFilter = SCContentFilter(display: display, excludingWindows: [])
      config.sourceRect = CGRect(x: region.x, y: region.y,
                                 width: region.widthPx, height: region.heightPx)
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
