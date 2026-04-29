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
      // Not enough room below — flip above.
      y = rect.minY - gap - toolbarSize.height
    }
    if y < displayBounds.minY || y + toolbarSize.height > displayBounds.maxY {
      // No room outside the rect — fall inside the rect, bottom-right inset by gap.
      x = rect.maxX - toolbarSize.width - gap
      y = rect.maxY - toolbarSize.height - gap
    }
    if x < displayBounds.minX { x = displayBounds.minX }
    if x + toolbarSize.width > displayBounds.maxX {
      x = displayBounds.maxX - toolbarSize.width
    }
    return CGPoint(x: x, y: y)
  }
}
