import XCTest
import CoreGraphics
@testable import screen_recorder_macos

final class SourceCatalogTests: XCTestCase {
  private func makeWindow(
    id: UInt32 = 100,
    title: String? = "Document",
    ownerName: String = "Example",
    bundleId: String = "com.example.app",
    width: CGFloat = 1200,
    height: CGFloat = 800
  ) -> RawWindow {
    return RawWindow(
      id: id,
      title: title,
      ownerName: ownerName,
      ownerBundleId: bundleId,
      frame: CGRect(x: 0, y: 0, width: width, height: height),
      isOnScreen: true
    )
  }

  func testKeepsRegularAppWindow() {
    let result = SourceCatalog.applyStrictFilter([makeWindow()])
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?["id"] as? String, "100")
  }

  func testDropsDockOwnedWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(bundleId: "com.apple.dock"),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsSystemUIServerOwnedWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(bundleId: "com.apple.systemuiserver"),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsControlCenterOwnedWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(bundleId: "com.apple.controlcenter"),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsNotificationCenterOwnedWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(bundleId: "com.apple.notificationcenterui"),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsWindowManagerOwnedWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(bundleId: "com.apple.WindowManager"),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsEmptyTitleWindow() {
    let result = SourceCatalog.applyStrictFilter([makeWindow(title: "")])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsNilTitleWindow() {
    let result = SourceCatalog.applyStrictFilter([makeWindow(title: nil)])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsWhitespaceOnlyTitleWindow() {
    let result = SourceCatalog.applyStrictFilter([makeWindow(title: "   ")])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsTooSmallWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(width: 40, height: 40),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testKeepsBoundaryWindowAtMinSize() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(width: 50, height: 50),
    ])
    XCTAssertEqual(result.count, 1)
  }

  func testDropsWindowThatIsTooShortButWideEnough() {
    let result = SourceCatalog.applyStrictFilter([makeWindow(width: 200, height: 30)])
    XCTAssertTrue(result.isEmpty)
  }

  func testProjectAllPassesThroughNilTitle() {
    let result = SourceCatalog.projectAll([makeWindow(title: nil)])
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?["title"] as? String, "")
  }

  func testProjectAllPassesThroughExcludedBundleId() {
    let result = SourceCatalog.projectAll([makeWindow(bundleId: "com.apple.dock")])
    XCTAssertEqual(result.count, 1)
  }

  func testEmittedDictionaryShape() {
    let result = SourceCatalog.applyStrictFilter([makeWindow()])
    let dict = result.first!
    XCTAssertEqual(dict["id"] as? String, "100")
    XCTAssertEqual(dict["title"] as? String, "Document")
    XCTAssertEqual(dict["ownerName"] as? String, "Example")
    XCTAssertEqual(dict["x"] as? Int, 0)
    XCTAssertEqual(dict["y"] as? Int, 0)
    XCTAssertEqual(dict["width"] as? Int, 1200)
    XCTAssertEqual(dict["height"] as? Int, 800)
    XCTAssertEqual(dict["isOnScreen"] as? Bool, true)
  }
}

final class SourcePickerGeometryTests: XCTestCase {
  func testLocalFrameSubtractsDisplayOrigin() {
    let display = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    let window = CGRect(x: 2020, y: 50, width: 400, height: 300)
    let local = SourcePickerGeometry.localFrame(window: window, displayBounds: display)
    XCTAssertEqual(local, CGRect(x: 100, y: 50, width: 400, height: 300))
  }

  func testTopmostReturnsFirstContainingFrameFrontToBack() {
    let frames = [
      CGRect(x: 0, y: 0, width: 100, height: 100),   // front
      CGRect(x: 200, y: 0, width: 100, height: 100),
      CGRect(x: 50, y: 50, width: 100, height: 100),  // back, overlaps front
    ]
    XCTAssertEqual(SourcePickerGeometry.topmost(at: CGPoint(x: 60, y: 60), frames: frames), 0)
  }

  func testTopmostReturnsNilOutsideAllFrames() {
    let frames = [CGRect(x: 0, y: 0, width: 10, height: 10)]
    XCTAssertNil(SourcePickerGeometry.topmost(at: CGPoint(x: 500, y: 500), frames: frames))
  }
}
