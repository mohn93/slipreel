import XCTest
@testable import screen_recorder_macos

final class RegionToolbarPositionTests: XCTestCase {
  private let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
  private let toolbarSize = CGSize(width: 140, height: 36)
  private let gap: CGFloat = 8

  func testPlacesAtBottomRightOfRectWithGap() {
    let rect = CGRect(x: 200, y: 200, width: 400, height: 300)
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: toolbarSize, gap: gap)
    XCTAssertEqual(p.x, 600 - 140)
    XCTAssertEqual(p.y, 500 + 8)
  }

  func testFlipsAboveWhenNotEnoughSpaceBelow() {
    let rect = CGRect(x: 200, y: 1000, width: 400, height: 70)
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: toolbarSize, gap: gap)
    XCTAssertEqual(p.x, 600 - 140)
    XCTAssertEqual(p.y, 1000 - 36 - 8)
  }

  func testFallsInsideWhenRectFillsDisplay() {
    let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: toolbarSize, gap: gap)
    XCTAssertEqual(p.x, 1920 - 140 - 8)
    XCTAssertEqual(p.y, 1080 - 36 - 8)
  }

  func testClampsLeftEdgeToDisplay() {
    let rect = CGRect(x: 0, y: 200, width: 80, height: 70)
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: toolbarSize, gap: gap)
    XCTAssertEqual(p.x, 0)
    XCTAssertEqual(p.y, 278)
  }

  func testClampsRightEdgeToDisplay() {
    // Rect anchored near the right edge — initial x = rect.maxX - toolbar.width
    // exceeds displayBounds.maxX, so the right-edge clamp must apply.
    let rect = CGRect(x: 1900, y: 200, width: 100, height: 100)
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: toolbarSize, gap: gap)
    XCTAssertEqual(p.x, 1920 - 140)
  }

  func testFallbackUsesRectNotDisplayBounds() {
    // Construct a scenario where neither below nor above fits, but the rect
    // does NOT fill the display. The fallback must anchor to the rect.
    let smallDisplay = CGRect(x: 0, y: 0, width: 800, height: 200)
    let rect = CGRect(x: 200, y: 0, width: 200, height: 160)
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: smallDisplay,
      toolbarSize: toolbarSize, gap: gap)
    // Below: y = 160 + 8 = 168, 168 + 36 = 204 > 200 → flip above
    // Above: y = 0 - 8 - 36 = -44 < 0 → fallback
    // Fallback (rect-relative): x = 400 - 140 - 8 = 252, y = 160 - 36 - 8 = 116
    XCTAssertEqual(p.x, 252)
    XCTAssertEqual(p.y, 116)
  }
}
