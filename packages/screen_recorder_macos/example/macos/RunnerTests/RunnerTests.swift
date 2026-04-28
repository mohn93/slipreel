// packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift
import Cocoa
import FlutterMacOS
import XCTest

@testable import screen_recorder_macos

class RunnerTests: XCTestCase {
  func testPluginInstantiates() {
    let plugin = ScreenRecorderMacosPlugin()
    XCTAssertNotNil(plugin)
  }
}
