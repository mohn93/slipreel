import XCTest
@testable import screen_recorder_macos

final class RegionSelectorStateTests: XCTestCase {
  private let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

  private func makeMachine() -> RegionSelectorMachine {
    return RegionSelectorMachine(displayBounds: displayBounds)
  }

  func testInitialStateIsIdle() {
    let m = makeMachine()
    if case .idle = m.state {} else { XCTFail("expected idle, got \(m.state)") }
  }

  func testIdleMouseDownStartsDrawing() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 100, y: 100)))
    guard case let .drawing(start, current) = m.state else {
      return XCTFail("expected drawing, got \(m.state)")
    }
    XCTAssertEqual(start, CGPoint(x: 100, y: 100))
    XCTAssertEqual(current, CGPoint(x: 100, y: 100))
  }

  func testDrawingMouseDraggedUpdatesCurrent() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 100, y: 100)))
    m.handle(.mouseDragged(to: CGPoint(x: 300, y: 250)))
    guard case let .drawing(_, current) = m.state else {
      return XCTFail("expected drawing")
    }
    XCTAssertEqual(current, CGPoint(x: 300, y: 250))
  }

  func testDrawingMouseUpAboveMinSizeBecomesSelected() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 100, y: 100)))
    m.handle(.mouseDragged(to: CGPoint(x: 300, y: 250)))
    m.handle(.mouseUp(at: CGPoint(x: 300, y: 250)))
    guard case let .selected(rect) = m.state else {
      return XCTFail("expected selected")
    }
    XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 200, height: 150))
  }

  func testDrawingMouseUpBelowMinSizeReturnsToIdle() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 100, y: 100)))
    m.handle(.mouseDragged(to: CGPoint(x: 130, y: 130)))
    m.handle(.mouseUp(at: CGPoint(x: 130, y: 130)))
    if case .idle = m.state {} else { XCTFail("expected idle, got \(m.state)") }
  }

  func testDrawingClipsToDisplayBounds() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 1800, y: 1000)))
    m.handle(.mouseDragged(to: CGPoint(x: 2500, y: 1500)))
    m.handle(.mouseUp(at: CGPoint(x: 2500, y: 1500)))
    guard case let .selected(rect) = m.state else {
      return XCTFail("expected selected")
    }
    XCTAssertEqual(rect.maxX, 1920)
    XCTAssertEqual(rect.maxY, 1080)
  }

  func testDrawingInvertsForBackwardsDrag() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 500, y: 500)))
    m.handle(.mouseDragged(to: CGPoint(x: 200, y: 200)))
    m.handle(.mouseUp(at: CGPoint(x: 200, y: 200)))
    guard case let .selected(rect) = m.state else {
      return XCTFail("expected selected")
    }
    XCTAssertEqual(rect, CGRect(x: 200, y: 200, width: 300, height: 300))
  }

  func testSelectedMouseDownOnHandleStartsResizing() {
    var m = makeMachine()
    let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
    m.setSelectedForTest(rect)
    m.handle(.mouseDown(at: CGPoint(x: 300, y: 250)))
    guard case let .resizing(handle, originalRect, _) = m.state else {
      return XCTFail("expected resizing, got \(m.state)")
    }
    XCTAssertEqual(handle, .se)
    XCTAssertEqual(originalRect, rect)
  }

  func testSelectedMouseDownInsideRectStartsMoving() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 200, y: 175)))
    if case .moving = m.state {} else { XCTFail("expected moving, got \(m.state)") }
  }

  func testSelectedMouseDownOutsideRectStartsNewDrawing() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 800, y: 800)))
    if case .drawing = m.state {} else { XCTFail("expected drawing, got \(m.state)") }
  }

  func testResizingSEHandleGrowsRect() {
    var m = makeMachine()
    let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
    m.setSelectedForTest(rect)
    m.handle(.mouseDown(at: CGPoint(x: 300, y: 250)))
    m.handle(.mouseDragged(to: CGPoint(x: 400, y: 300)))
    guard case let .resizing(_, _, _) = m.state else {
      return XCTFail("expected resizing")
    }
    XCTAssertEqual(m.currentRect, CGRect(x: 100, y: 100, width: 300, height: 200))
  }

  func testResizingMouseUpReturnsToSelected() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 300, y: 250)))
    m.handle(.mouseDragged(to: CGPoint(x: 400, y: 300)))
    m.handle(.mouseUp(at: CGPoint(x: 400, y: 300)))
    guard case let .selected(rect) = m.state else {
      return XCTFail("expected selected")
    }
    XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 300, height: 200))
  }

  func testMovingTranslatesRect() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 200, y: 175)))
    m.handle(.mouseDragged(to: CGPoint(x: 250, y: 200)))
    XCTAssertEqual(m.currentRect, CGRect(x: 150, y: 125, width: 200, height: 150))
  }

  func testMovingClipsToDisplayBounds() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 200, y: 175)))
    m.handle(.mouseDragged(to: CGPoint(x: 5000, y: 5000)))
    let r = m.currentRect
    XCTAssertEqual(r.maxX, 1920)
    XCTAssertEqual(r.maxY, 1080)
    XCTAssertEqual(r.width, 200)
    XCTAssertEqual(r.height, 150)
  }

  func testEscapeFromDrawingCancels() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 100, y: 100)))
    m.handle(.escapePressed)
    if case .cancelled = m.state {} else { XCTFail("expected cancelled") }
  }

  func testEscapeFromSelectedCancels() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.escapePressed)
    if case .cancelled = m.state {} else { XCTFail("expected cancelled") }
  }

  func testEscapeFromResizingCancels() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 300, y: 250)))
    m.handle(.escapePressed)
    if case .cancelled = m.state {} else { XCTFail("expected cancelled") }
  }

  func testEscapeFromMovingCancels() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 200, y: 175)))
    m.handle(.escapePressed)
    if case .cancelled = m.state {} else { XCTFail("expected cancelled") }
  }

  func testEscapeFromConfirmedIsIgnored() {
    var m = makeMachine()
    let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
    m.setSelectedForTest(rect)
    m.handle(.startPressed)
    m.handle(.escapePressed)
    guard case let .confirmed(r) = m.state else {
      return XCTFail("expected confirmed (terminal), got \(m.state)")
    }
    XCTAssertEqual(r, rect)
  }

  func testDrawingMouseUpAtExactlyMinSizeBecomesSelected() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 100, y: 100)))
    m.handle(.mouseUp(at: CGPoint(x: 150, y: 150)))
    guard case let .selected(rect) = m.state else {
      return XCTFail("expected selected at exact 50x50 boundary, got \(m.state)")
    }
    XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 50, height: 50))
  }

  func testResizingBelowMinSizeRevertsToOriginal() {
    var m = makeMachine()
    let rect = CGRect(x: 200, y: 200, width: 200, height: 150)
    m.setSelectedForTest(rect)
    m.handle(.mouseDown(at: CGPoint(x: 400, y: 350))) // SE handle
    m.handle(.mouseUp(at: CGPoint(x: 210, y: 210)))   // drag SE far toward NW
    guard case let .selected(r) = m.state else {
      return XCTFail("expected selected, got \(m.state)")
    }
    XCTAssertEqual(r, rect, "resizing below minSize should revert to original")
  }

  func testStartFromSelectedConfirms() {
    var m = makeMachine()
    let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
    m.setSelectedForTest(rect)
    m.handle(.startPressed)
    guard case let .confirmed(confirmedRect) = m.state else {
      return XCTFail("expected confirmed")
    }
    XCTAssertEqual(confirmedRect, rect)
  }

  func testCancelButtonFromSelectedCancels() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.cancelPressed)
    if case .cancelled = m.state {} else { XCTFail("expected cancelled") }
  }

  func testStartFromIdleIsIgnored() {
    var m = makeMachine()
    m.handle(.startPressed)
    if case .idle = m.state {} else { XCTFail("expected idle, got \(m.state)") }
  }
}
