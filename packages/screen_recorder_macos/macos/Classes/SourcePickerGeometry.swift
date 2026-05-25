import CoreGraphics

/// Pure geometry for the source-picker overlay. Kept separate from the
/// AppKit view so it can be unit-tested (the view itself is not).
enum SourcePickerGeometry {
  /// Converts a window's global CG frame (top-left origin) into coordinates
  /// local to a display whose CG bounds are `displayBounds` — a simple origin
  /// subtraction. The overlay view is flipped (top-left), so no Y inversion.
  static func localFrame(window: CGRect, displayBounds: CGRect) -> CGRect {
    return CGRect(
      x: window.origin.x - displayBounds.origin.x,
      y: window.origin.y - displayBounds.origin.y,
      width: window.size.width,
      height: window.size.height)
  }

  /// Given frames ordered front-to-back, returns the index of the first
  /// (front-most) frame containing `point`, or nil if none do.
  static func topmost(at point: CGPoint, frames: [CGRect]) -> Int? {
    for (i, f) in frames.enumerated() where f.contains(point) {
      return i
    }
    return nil
  }
}
