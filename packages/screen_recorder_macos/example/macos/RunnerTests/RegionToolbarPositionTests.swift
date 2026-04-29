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
  }
}
