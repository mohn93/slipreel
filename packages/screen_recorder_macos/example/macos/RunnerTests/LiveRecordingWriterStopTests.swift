import XCTest
import AVFoundation
@testable import screen_recorder_macos

/// Regression tests for `LiveRecordingWriter.stop()` when the writer session
/// never opened — e.g. an iPhone/iPad device source whose screen was off, so
/// no compressed video sample ever arrived and `startWriting()`/`startSession()`
/// were never called.
///
/// Before the fix, `stop()` called `markAsFinished()` on the pre-created audio
/// inputs BEFORE the `!writerActive` early-return. `AVAssetWriterInput.markAsFinished()`
/// on a writer whose status is still `.unknown` throws an Objective-C exception
/// → uncatchable in Swift → SIGABRT (process abort). This test would crash the
/// whole test runner in that case.
final class LiveRecordingWriterStopTests: XCTestCase {
  private func tmpPath() -> String {
    NSTemporaryDirectory() + "live_writer_stop_\(UUID().uuidString).mp4"
  }

  /// start() then stop() with NO video frame appended must return
  /// `noFramesWritten` gracefully (and must not abort the process), even when
  /// an audio track was configured (audio inputs are created up-front in start()).
  func testStopWithoutVideoFramesReturnsNoFramesWritten() {
    let path = tmpPath()
    addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

    let writer = LiveRecordingWriter(
      outputPath: path, width: 1920, height: 1080, fps: 60,
      audioTracks: [.microphone])
    XCTAssertNoThrow(try writer.start())

    let done = expectation(description: "stop completes")
    var result: Result<String, Error>?
    writer.stop { r in
      result = r
      done.fulfill()
    }
    wait(for: [done], timeout: 5)

    guard case .failure(let error)? = result else {
      XCTFail("expected failure(noFramesWritten), got \(String(describing: result))")
      return
    }
    guard case LiveRecordingWriter.WriterError.noFramesWritten = error else {
      XCTFail("expected WriterError.noFramesWritten, got \(error)")
      return
    }
  }

  /// The same, with no audio tracks at all — the all-nil-input path must also
  /// finalize gracefully rather than crash.
  func testStopWithoutVideoOrAudioReturnsNoFramesWritten() {
    let path = tmpPath()
    addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

    let writer = LiveRecordingWriter(
      outputPath: path, width: 1920, height: 1080, fps: 60, audioTracks: [])
    XCTAssertNoThrow(try writer.start())

    let done = expectation(description: "stop completes")
    var result: Result<String, Error>?
    writer.stop { r in
      result = r
      done.fulfill()
    }
    wait(for: [done], timeout: 5)

    guard case .failure(let error)? = result,
          case LiveRecordingWriter.WriterError.noFramesWritten = error else {
      XCTFail("expected WriterError.noFramesWritten, got \(String(describing: result))")
      return
    }
  }
}
