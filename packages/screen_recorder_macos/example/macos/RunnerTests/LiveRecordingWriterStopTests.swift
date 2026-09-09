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
  func testCameraWriterPersistsRecoveryTimingAndFinalizesFragmentedVideo() throws {
    let path = NSTemporaryDirectory() + "camera_recovery_\(UUID().uuidString).mov"
    addTeardownBlock {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + ".start-time")
    }
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
      kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
    let pixel = try XCTUnwrap(pixelBuffer)
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixel, formatDescriptionOut: &format), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(seconds: 100.25, preferredTimescale: 600),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixel, formatDescription: try XCTUnwrap(format),
      sampleTiming: &timing, sampleBufferOut: &sample), noErr)
    let writer = CameraSidecarWriter(outputPath: path, width: 64, height: 64)
    try writer.start()
    writer.append(try XCTUnwrap(sample))
    XCTAssertEqual(try String(contentsOfFile: path + ".start-time", encoding: .utf8), "100.25")
    let done = expectation(description: "camera finalizes")
    writer.stop { result in
      if case .failure(let error) = result { XCTFail("Camera finalization failed: \(error)") }
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    XCTAssertEqual(asset.tracks(withMediaType: .video).count, 1)
  }
}
