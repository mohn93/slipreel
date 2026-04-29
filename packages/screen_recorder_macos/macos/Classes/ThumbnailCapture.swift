import Foundation
import CoreGraphics
import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

enum ThumbnailKind: String {
  case window
  case screen
}

protocol OSVersionProbe {
  var isMacOS14OrLater: Bool { get }
}

struct LiveOSVersionProbe: OSVersionProbe {
  var isMacOS14OrLater: Bool {
    if #available(macOS 14.0, *) { return true }
    return false
  }
}

/// Errors thumbnail capture can surface to the plugin layer. Plugins should
/// translate to `null` (not error) so the UI can fall back to an icon.
enum ThumbnailCaptureError: Error {
  case sourceNotFound
  case captureFailed
  case encodeFailed
}

enum ThumbnailCapture {
  /// Capture a JPEG thumbnail for `sourceId` with longest edge ≤ `maxDimension`.
  /// The three `*Capture` closure parameters are seams for testing — callers
  /// rely on the production defaults and should not pass them.
  static func capture(
    sourceId: String,
    kind: ThumbnailKind,
    maxDimension: Int,
    osVersion: OSVersionProbe = LiveOSVersionProbe(),
    modernCapture: ((String, ThumbnailKind, Int, Int) async throws -> Data)? = nil,
    legacyWindowCapture: ((CGWindowID, Int) async throws -> Data)? = nil,
    legacyDisplayCapture: ((CGDirectDisplayID, Int) async throws -> Data)? = nil
  ) async throws -> Data {
    if osVersion.isMacOS14OrLater {
      let fn = modernCapture ?? defaultModernCapture
      return try await fn(sourceId, kind, maxDimension, maxDimension)
    }
    switch kind {
    case .window:
      guard let id = CGWindowID(sourceId) else { throw ThumbnailCaptureError.sourceNotFound }
      let fn = legacyWindowCapture ?? defaultLegacyWindowCapture
      return try await fn(id, maxDimension)
    case .screen:
      guard let id = CGDirectDisplayID(sourceId) else { throw ThumbnailCaptureError.sourceNotFound }
      let fn = legacyDisplayCapture ?? defaultLegacyDisplayCapture
      return try await fn(id, maxDimension)
    }
  }

  // MARK: - Default capture implementations

  private static let defaultModernCapture: (String, ThumbnailKind, Int, Int) async throws -> Data = { sourceId, kind, maxW, _ in
    if #available(macOS 14.0, *) {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      let filter: SCContentFilter
      let nativeSize: CGSize
      switch kind {
      case .window:
        guard let id = UInt32(sourceId),
              let w = content.windows.first(where: { $0.windowID == id }) else {
          throw ThumbnailCaptureError.sourceNotFound
        }
        filter = SCContentFilter(desktopIndependentWindow: w)
        nativeSize = w.frame.size
      case .screen:
        guard let id = UInt32(sourceId),
              let d = content.displays.first(where: { $0.displayID == id }) else {
          throw ThumbnailCaptureError.sourceNotFound
        }
        filter = SCContentFilter(display: d, excludingWindows: [])
        nativeSize = CGSize(width: d.width, height: d.height)
      }
      // Preserve the source's aspect ratio so the framebuffer is not letterboxed
      // (SCKit pads to whatever the configured width/height demand, producing
      // visible bars otherwise).
      let aspect = nativeSize.width > 0 && nativeSize.height > 0
        ? nativeSize.width / nativeSize.height
        : 1.0
      let targetW: Int
      let targetH: Int
      if aspect >= 1 {
        targetW = maxW
        targetH = max(1, Int(CGFloat(maxW) / aspect))
      } else {
        targetH = maxW
        targetW = max(1, Int(CGFloat(maxW) * aspect))
      }
      let config = SCStreamConfiguration()
      config.showsCursor = false
      config.width = targetW
      config.height = targetH
      let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
      return try jpegData(from: cgImage)
    }
    throw ThumbnailCaptureError.captureFailed
  }

  private static let defaultLegacyWindowCapture: (CGWindowID, Int) async throws -> Data = { id, maxDim in
    // Deprecated in macOS 14 but not removed; this closure is only reached on 12.3-13.
    guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]) else {
      throw ThumbnailCaptureError.captureFailed
    }
    let downsampled = downsample(cgImage, maxDimension: maxDim)
    return try jpegData(from: downsampled)
  }

  private static let defaultLegacyDisplayCapture: (CGDirectDisplayID, Int) async throws -> Data = { id, maxDim in
    // Deprecated in macOS 14 but not removed; this closure is only reached on 12.3-13.
    guard let cgImage = CGDisplayCreateImage(id) else {
      throw ThumbnailCaptureError.captureFailed
    }
    let downsampled = downsample(cgImage, maxDimension: maxDim)
    return try jpegData(from: downsampled)
  }

  // MARK: - Helpers

  private static func downsample(_ image: CGImage, maxDimension: Int) -> CGImage {
    let w = image.width
    let h = image.height
    let longEdge = max(w, h)
    if longEdge <= maxDimension { return image }
    let scale = CGFloat(maxDimension) / CGFloat(longEdge)
    let newW = Int(CGFloat(w) * scale)
    let newH = Int(CGFloat(h) * scale)
    let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
      data: nil, width: newW, height: newH, bitsPerComponent: 8,
      bytesPerRow: 0, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return image }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
    return ctx.makeImage() ?? image
  }

  private static func jpegData(from image: CGImage) throws -> Data {
    let mutable = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
      mutable, UTType.jpeg.identifier as CFString, 1, nil
    ) else { throw ThumbnailCaptureError.encodeFailed }
    let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
    CGImageDestinationAddImage(dest, image, opts as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw ThumbnailCaptureError.encodeFailed }
    return mutable as Data
  }
}
