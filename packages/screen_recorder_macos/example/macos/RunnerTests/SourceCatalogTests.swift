import XCTest
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
