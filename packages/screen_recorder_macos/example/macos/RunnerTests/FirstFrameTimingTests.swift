import XCTest
@testable import screen_recorder_macos

final class FirstFrameTimingTests: XCTestCase {
  // MARK: - captureInstant

  /// Healthy case: a frame observed 50ms after capture should back-date
  /// the capture instant by exactly 50ms.
  func testCaptureInstantBackDatesByPositiveAge() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    let captured = FirstFrameTiming.captureInstant(
      nowWall: now,
      hostNowSeconds: 12_345.05,
      ptsSeconds: 12_345.00)
    XCTAssertEqual(
      captured.timeIntervalSince(now), -0.05, accuracy: 1e-9)
  }

  /// Larger SCStream warmup latency (200ms) — still back-dates.
  func testCaptureInstantHandlesLargeWarmupLatency() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    let captured = FirstFrameTiming.captureInstant(
      nowWall: now,
      hostNowSeconds: 12_345.20,
      ptsSeconds: 12_345.00)
    XCTAssertEqual(
      captured.timeIntervalSince(now), -0.20, accuracy: 1e-9)
  }

  /// pts that's somehow ahead of host now (clock skew, or pts in the
  /// future after a config change) must clamp to age=0 — projecting
  /// the capture instant into the future would make every subsequent
  /// cursor sample's elapsed time negative and they'd all get dropped.
  func testCaptureInstantClampsNegativeAgeToZero() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    let captured = FirstFrameTiming.captureInstant(
      nowWall: now,
      hostNowSeconds: 12_345.00,
      ptsSeconds: 12_345.50)
    XCTAssertEqual(captured, now)
  }

  /// Exactly-equal host now and pts → age 0 → capture instant equals
  /// nowWall.
  func testCaptureInstantHandlesZeroAge() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    let captured = FirstFrameTiming.captureInstant(
      nowWall: now,
      hostNowSeconds: 12_345.00,
      ptsSeconds: 12_345.00)
    XCTAssertEqual(captured, now)
  }

  /// NaN pts (which `CMTimeGetSeconds` returns for invalid CMTime
  /// values) must clamp to age=0 instead of producing a NaN-valued
  /// Date that poisons every subsequent cursor sample.
  func testCaptureInstantClampsNaNPtsToZero() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    let captured = FirstFrameTiming.captureInstant(
      nowWall: now,
      hostNowSeconds: 12_345.00,
      ptsSeconds: .nan)
    XCTAssertEqual(captured, now)
  }

  /// Likewise for non-finite host now.
  func testCaptureInstantClampsInfiniteHostNowToZero() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    let captured = FirstFrameTiming.captureInstant(
      nowWall: now,
      hostNowSeconds: .infinity,
      ptsSeconds: 12_345.00)
    XCTAssertEqual(captured, now)
  }

  // MARK: - videoMicros

  /// Cursor sample fired before any frame arrived (frame start hasn't
  /// been stamped yet — the plugin guards on `firstVideoFrameAt == nil`
  /// before this call) — but if for any reason `now` is somehow before
  /// `frameStart`, drop the sample.
  func testVideoMicrosDropsSampleBeforeFrameStart() {
    let frameStart = Date(timeIntervalSince1970: 1_000_001)
    let earlier = Date(timeIntervalSince1970: 1_000_000.999)
    XCTAssertNil(FirstFrameTiming.videoMicros(
      now: earlier, since: frameStart))
  }

  /// At exactly the frame start instant → 0 micros (kept, not dropped).
  func testVideoMicrosAtFrameStartReturnsZero() {
    let frameStart = Date(timeIntervalSinceReferenceDate: 0)
    XCTAssertEqual(
      FirstFrameTiming.videoMicros(now: frameStart, since: frameStart),
      0)
  }

  /// 50ms after frame start → 50_000 micros.
  func testVideoMicrosReturnsElapsedMicrosAfterFrameStart() {
    let frameStart = Date(timeIntervalSinceReferenceDate: 0)
    let later = frameStart.addingTimeInterval(0.05)
    XCTAssertEqual(
      FirstFrameTiming.videoMicros(now: later, since: frameStart),
      50_000)
  }

  /// Multi-second elapsed (5.36s, matching production data) → exact
  /// micros. Precision sanity-check: TimeInterval is Double so very
  /// long recordings stay accurate to micro granularity.
  func testVideoMicrosHandlesMultiSecondElapsed() {
    let frameStart = Date(timeIntervalSinceReferenceDate: 0)
    let later = frameStart.addingTimeInterval(5.360329)
    XCTAssertEqual(
      FirstFrameTiming.videoMicros(now: later, since: frameStart),
      5_360_329)
  }

  // MARK: - Round-trip

  /// End-to-end: capture instant computed from synthetic clocks, then
  /// a cursor sample observed `cursorElapsed` after the original
  /// capture moment — its video-micros must equal `cursorElapsed * 1e6`.
  /// This is the property the cursor-follow zoom relies on: the same
  /// number of micros passed in the real world appears in the
  /// timestamps of cursor samples relative to video frames.
  func testRoundTripFromCaptureToCursorSample() {
    // Pretend the first frame was actually captured at hostTime 12_345.0
    // and our handler observed it at hostTime 12_345.08 (80ms warmup).
    // The Date() we observe at handler time is `nowWall`.
    let nowWall = Date(timeIntervalSinceReferenceDate: 0)
    let frameStart = FirstFrameTiming.captureInstant(
      nowWall: nowWall,
      hostNowSeconds: 12_345.08,
      ptsSeconds: 12_345.00)
    // 200ms after the actual frame capture, a cursor sample fires.
    // In wall time: nowWall - 0.08 (frame capture) + 0.20 = nowWall + 0.12.
    let cursorObservedAt = nowWall.addingTimeInterval(0.12)
    let micros = FirstFrameTiming.videoMicros(
      now: cursorObservedAt, since: frameStart)
    XCTAssertEqual(micros, 200_000)
  }
}
