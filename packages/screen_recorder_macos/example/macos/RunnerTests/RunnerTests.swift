import Cocoa
import FlutterMacOS
import XCTest

@testable import screen_recorder_macos

class RunnerTests: XCTestCase {
  func testPluginInstantiates() {
    let plugin = ScreenRecorderMacosPlugin()
    XCTAssertNotNil(plugin)
  }

  func testListSourcesRejectsBadArgs() {
    let plugin = ScreenRecorderMacosPlugin()
    let call = FlutterMethodCall(methodName: "listSources", arguments: "not a dict")
    let exp = expectation(description: "result")
    plugin.handle(call) { result in
      let err = result as? FlutterError
      XCTAssertEqual(err?.code, "INVALID_ARGUMENTS")
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testCaptureThumbnailRejectsBadArgs() {
    let plugin = ScreenRecorderMacosPlugin()
    let call = FlutterMethodCall(methodName: "captureThumbnail", arguments: ["id": "1"])
    let exp = expectation(description: "result")
    plugin.handle(call) { result in
      let err = result as? FlutterError
      XCTAssertEqual(err?.code, "INVALID_ARGUMENTS")
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testCaptureThumbnailRejectsBadKind() {
    let plugin = ScreenRecorderMacosPlugin()
    let call = FlutterMethodCall(
      methodName: "captureThumbnail",
      arguments: ["id": "1", "kind": "potato", "maxDimension": 240]
    )
    let exp = expectation(description: "result")
    plugin.handle(call) { result in
      let err = result as? FlutterError
      XCTAssertEqual(err?.code, "INVALID_ARGUMENTS")
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }
}
