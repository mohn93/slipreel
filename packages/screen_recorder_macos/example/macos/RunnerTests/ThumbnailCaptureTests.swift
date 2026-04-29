import XCTest
@testable import screen_recorder_macos

final class ThumbnailCaptureTests: XCTestCase {
  func testPicksModernPathOnSonomaPlus() async throws {
    let probe = StubOSVersionProbe(isMacOS14OrLater: true)
    var pickedModern = false
    var pickedLegacyWindow = false
    var pickedLegacyDisplay = false
    let result = try? await ThumbnailCapture.capture(
      sourceId: "1",
      kind: .window,
      maxDimension: 240,
      osVersion: probe,
      modernCapture: { _, _, _, _ in pickedModern = true; return Data([0xFF]) },
      legacyWindowCapture: { _, _ in pickedLegacyWindow = true; return Data() },
      legacyDisplayCapture: { _, _ in pickedLegacyDisplay = true; return Data() }
    )
    XCTAssertTrue(pickedModern)
    XCTAssertFalse(pickedLegacyWindow)
    XCTAssertFalse(pickedLegacyDisplay)
    XCTAssertEqual(result, Data([0xFF]))
  }

  func testPicksLegacyWindowPathOnVentura() async throws {
    let probe = StubOSVersionProbe(isMacOS14OrLater: false)
    var pickedModern = false
    var pickedLegacyWindow = false
    var pickedLegacyDisplay = false
    let result = try await ThumbnailCapture.capture(
      sourceId: "42",
      kind: .window,
      maxDimension: 240,
      osVersion: probe,
      modernCapture: { _, _, _, _ in pickedModern = true; return Data() },
      legacyWindowCapture: { id, _ in pickedLegacyWindow = true; XCTAssertEqual(id, 42); return Data([0xAB]) },
      legacyDisplayCapture: { _, _ in pickedLegacyDisplay = true; return Data() }
    )
    XCTAssertFalse(pickedModern)
    XCTAssertTrue(pickedLegacyWindow)
    XCTAssertFalse(pickedLegacyDisplay)
    XCTAssertFalse(result.isEmpty)
  }

  func testPicksLegacyDisplayPathOnVentura() async throws {
    let probe = StubOSVersionProbe(isMacOS14OrLater: false)
    var pickedModern = false
    var pickedLegacyWindow = false
    var pickedLegacyDisplay = false
    let result = try await ThumbnailCapture.capture(
      sourceId: "100",
      kind: .screen,
      maxDimension: 240,
      osVersion: probe,
      modernCapture: { _, _, _, _ in pickedModern = true; return Data() },
      legacyWindowCapture: { _, _ in pickedLegacyWindow = true; return Data() },
      legacyDisplayCapture: { id, _ in pickedLegacyDisplay = true; XCTAssertEqual(id, 100); return Data([0xCD]) }
    )
    XCTAssertFalse(pickedModern)
    XCTAssertFalse(pickedLegacyWindow)
    XCTAssertTrue(pickedLegacyDisplay)
    XCTAssertFalse(result.isEmpty)
  }
}

private struct StubOSVersionProbe: OSVersionProbe {
  let isMacOS14OrLater: Bool
}
