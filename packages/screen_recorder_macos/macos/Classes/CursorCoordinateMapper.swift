import CoreGraphics
import Foundation

/// Pure functions that map a global cursor point (NSEvent.mouseLocation —
/// AppKit bottom-left origin, in screen points) into the recorded
/// video's pixel space (top-left origin, inside the captured rect).
///
/// Kept separate from `ScreenRecorderMacosPlugin` so the math can be unit
/// tested without an `NSScreen`. The plugin still owns the
/// display-lookup; this type just consumes the geometry it produces.
enum CursorCoordinateMapper {
  /// Map a cursor point captured during a full-display recording. The
  /// effective scale is derived from the recorded video size vs the
  /// display's point dimensions — NOT from `backingScaleFactor` —
  /// because on Apple Silicon SCStream may capture at logical-point
  /// resolution while the screen still reports backingScaleFactor 2.0.
  static func mapForScreen(
    cursorGlobalX gx: Double,
    cursorGlobalY gy: Double,
    displayMinX: Double,
    displayMaxY: Double,
    displayWidthPts: Double,
    displayHeightPts: Double,
    videoWidthPx: Int,
    videoHeightPx: Int
  ) -> (x: Double, y: Double) {
    let pixelsPerPointX = Double(videoWidthPx) / displayWidthPts
    let pixelsPerPointY = Double(videoHeightPx) / displayHeightPts
    let xInDisplayPts = gx - displayMinX
    let yInDisplayPts = displayMaxY - gy
    return (xInDisplayPts * pixelsPerPointX,
            yInDisplayPts * pixelsPerPointY)
  }

  /// Map a cursor point captured during an area (region) recording. For
  /// area capture the SCStream framebuffer width equals the region's
  /// pixel width, so pixels-per-point equals the display's
  /// `backingScaleFactor`.
  ///
  /// `regionXPx` / `regionYPx` are the region origin in display pixels
  /// (top-left), as supplied by the region selector.
  static func mapForArea(
    cursorGlobalX gx: Double,
    cursorGlobalY gy: Double,
    displayMinX: Double,
    displayMaxY: Double,
    backingScale: Double,
    regionXPx: Double,
    regionYPx: Double
  ) -> (x: Double, y: Double) {
    let regionLocalXPts = regionXPx / backingScale
    let regionLocalYPts = regionYPx / backingScale
    let xInDisplayPts = gx - displayMinX
    let yInDisplayPts = displayMaxY - gy
    let xPx = (xInDisplayPts - regionLocalXPts) * backingScale
    let yPx = (yInDisplayPts - regionLocalYPts) * backingScale
    return (xPx, yPx)
  }
}
