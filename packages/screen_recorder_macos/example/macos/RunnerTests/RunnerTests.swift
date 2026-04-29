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

  func testSelectRegionMethodIsDispatched() {
    let plugin = ScreenRecorderMacosPlugin()
    let call = FlutterMethodCall(methodName: "selectRegion", arguments: nil)
    let exp = expectation(description: "result")
    plugin.handle(call) { result in
      // We can't actually open windows in CI, but the dispatch should at least
      // not return FlutterMethodNotImplemented. Result will be nil (canceled
      // because no UI is showing) — that's the expected null-on-cancel value.
      XCTAssertFalse((result as AnyObject) === (FlutterMethodNotImplemented as AnyObject))
      exp.fulfill()
    }
    // Cancel any pending selection so the handler resolves immediately.
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
      RegionSelector.shared.cancel()
    }
    waitForExpectations(timeout: 2)
  }

  func testStartLiveRecordingRejectsBadRegionShape() {
    let plugin = ScreenRecorderMacosPlugin()
    let call = FlutterMethodCall(
      methodName: "startLiveRecording",
      arguments: [
        "source": "area",
        "frameRate": 30,
        "outputPath": "/tmp/test.mp4",
        "region": "not a map",
      ]
    )
    let exp = expectation(description: "result")
    plugin.handle(call) { result in
      let err = result as? FlutterError
      XCTAssertEqual(err?.code, "INVALID_ARGUMENTS")
      exp.fulfill()
    }
    waitForExpectations(timeout: 2)
  }
}
