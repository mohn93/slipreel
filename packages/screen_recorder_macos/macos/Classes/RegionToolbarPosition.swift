import Foundation
import CoreGraphics

enum RegionToolbarPosition {
  static func positionFor(
    rect: CGRect,
    displayBounds: CGRect,
    toolbarSize: CGSize,
    gap: CGFloat
  ) -> CGPoint {
    var x = rect.maxX - toolbarSize.width
    var y = rect.maxY + gap

    if y + toolbarSize.height > displayBounds.maxY {
      y = rect.minY - gap - toolbarSize.height
    }
    if y < displayBounds.minY || y + toolbarSize.height > displayBounds.maxY {
      x = displayBounds.maxX - toolbarSize.width - gap
      y = displayBounds.maxY - toolbarSize.height - gap
    }
    if x < displayBounds.minX { x = displayBounds.minX }
    if x + toolbarSize.width > displayBounds.maxX {
      x = displayBounds.maxX - toolbarSize.width
    }
    return CGPoint(x: x, y: y)
  }
}
