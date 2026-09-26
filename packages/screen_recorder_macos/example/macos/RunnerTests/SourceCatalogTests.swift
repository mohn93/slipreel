import XCTest
import CoreGraphics
import AppKit
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

  func testPickerKeepsSiblingWindowsIncludingUntitledOnes() {
    let windows = [
      makeWindow(id: 100, title: "First"),
      makeWindow(id: 101, title: nil),
      makeWindow(id: 102, title: "Second"),
    ]
    XCTAssertEqual(SourceCatalog.pickableWindows(windows).map(\.id), [100, 101, 102])
  }

  func testPickerUsesFrontmostOrderForOverlappingWindows() {
    let windows = [makeWindow(id: 100), makeWindow(id: 101), makeWindow(id: 102)]
    let ordered = SourceCatalog.frontToBack(windows, orderedIDs: [102, 100])
    XCTAssertEqual(ordered.map(\.id), [102, 100, 101])
  }

  func testPickerStillExcludesSystemAndTinyWindows() {
    let windows = [
      makeWindow(id: 100, bundleId: "com.apple.dock"),
      makeWindow(id: 101, width: 40),
      makeWindow(id: 102),
      makeWindow(id: 103, ownerName: "Wallpaper", bundleId: "com.apple.wallpaper.agent"),
    ]
    XCTAssertEqual(SourceCatalog.pickableWindows(windows).map(\.id), [102])
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

final class SourcePickerViewTests: XCTestCase {
  func testCancelSitsBelowRecordAndStillCancelsSelection() {
    let view = SourcePickerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    let frame = CGRect(x: 100, y: 100, width: 500, height: 400)
    view.targets = [
      PickerTarget(id: "100", title: "Document", appName: "Example",
                   icon: nil, localFrame: frame),
    ]
    view.keyboardSelectedID = "100"
    view.layoutSubtreeIfNeeded()

    let cancel = view.subviews.compactMap { $0 as? NSButton }.first!
    XCTAssertEqual(cancel.frame.midX, frame.midX)
    XCTAssertEqual(cancel.frame.minY, frame.midY + 58)
    XCTAssertEqual(cancel.frame.size, CGSize(width: 116, height: 32))

    var canceled = false
    view.onCancel = { canceled = true }
    cancel.performClick(nil)
    XCTAssertTrue(canceled)

    view.keyboardSelectedID = nil
    XCTAssertEqual(cancel.frame.midX, view.bounds.midX)
  }

  func testRepeatedAppAndWindowTitleUsesOneLineWithoutWindowChips() {
    let view = SourcePickerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
    let frame = CGRect(x: 100, y: 100, width: 500, height: 400)
    view.targets = [
      PickerTarget(id: "100", title: "ChatGPT", appName: "ChatGPT", icon: nil, localFrame: frame),
      PickerTarget(id: "101", title: "Document", appName: "Example", icon: nil, localFrame: frame),
    ]
    XCTAssertEqual(SourcePickerView.labelLines(for: view.targets[0]), ["ChatGPT"])
    XCTAssertEqual(SourcePickerView.labelLines(for: view.targets[1]), ["Example", "Document"])
    XCTAssertFalse(view.subviews.contains { $0 is NSScrollView })
  }
}
