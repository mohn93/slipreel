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

  // MARK: - Recording Control

  /// Start capturing screen or window
  /// - Parameters:
  ///   - sourceId: The display ID or window ID to capture
  ///   - fps: Frames per second (30 or 60)
  ///   - isWindow: Whether the sourceId refers to a window (true) or display (false)
  func startCapture(sourceId: String, fps: Int, isWindow: Bool, showCursor: Bool = true) async throws {
    guard !isCapturing else {
      throw ScreenCaptureError.alreadyCapturing
    }

    // Get shareable content
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    // Create content filter based on source type
    if isWindow {
      // Capture specific window
      guard let windowID = UInt32(sourceId),
            let window = content.windows.first(where: { $0.windowID == windowID }) else {
        throw ScreenCaptureError.invalidSourceId
      }
      contentFilter = SCContentFilter(desktopIndependentWindow: window)
    } else {
      // Capture display
      guard let displayID = UInt32(sourceId),
            let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw ScreenCaptureError.invalidSourceId
      }

      // Exclude desktop windows for cleaner capture
      let excludedApps = content.applications.filter { app in
        // Exclude Finder and Dock
        app.bundleIdentifier == "com.apple.finder" ||
        app.bundleIdentifier == "com.apple.dock"
      }

      contentFilter = SCContentFilter(
        display: display,
        excludingApplications: excludedApps,
        exceptingWindows: []
      )
    }

    // Configure stream
    let config = SCStreamConfiguration()

    // Set frame rate
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))

    // Set pixel format (BGRA is most common and efficient)
    config.pixelFormat = kCVPixelFormatType_32BGRA

    // Enable high resolution capture
    config.scalesToFit = false
    config.showsCursor = showCursor

    // Set capture resolution based on source
    if isWindow {
      // For windows, use actual window size in pixels (frame is in logical points)
      if let window = content.windows.first(where: { $0.windowID == UInt32(sourceId) ?? 0 }) {
        let scale = NSScreen.main?.backingScaleFactor ?? 1.0
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
      }
    } else {
      // For displays, use native resolution
      if let display = content.displays.first(where: { $0.displayID == UInt32(sourceId) ?? 0 }) {
        config.width = display.width
        config.height = display.height
      }
    }

    // Quality settings
    config.queueDepth = 5 // Buffer up to 5 frames

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
