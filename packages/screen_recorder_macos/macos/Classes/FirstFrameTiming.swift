import Foundation

/// Pure helpers that pin cursor sample timestamps to the wall-clock
/// instant the first SCStream frame was captured, so the cursor track
/// and the recorded video share a 0-based time origin in playback.
///
/// The plugin owns the two time-domain reads (`CMClockGetHostTimeClock`
/// for `hostNowSeconds`, `CMSampleBufferGetPresentationTimeStamp` for
/// `ptsSeconds`, and `Date()` for `nowWall`); this type just does the
/// arithmetic. Kept separate so XCTest can drive it with synthetic
/// inputs — the math is small but the failure modes (NaN pts on
/// invalid CMTime, negative age from clock skew, or pre-warmup cursor
/// samples collapsing to t=0) are all silent regressions when wrong.
enum FirstFrameTiming {
  /// Compute the wall-clock instant when the first video frame was
  /// captured, given the current host-clock time, the frame's pts (also
  /// in host-clock seconds), and the current wall clock. SCStream's
  /// callback arrives some ms after the actual capture due to
  /// compression/dispatch latency — subtracting `hostNow − pts` from
  /// `Date()` recovers the true capture instant.
  ///
  /// Clamps the computed age to zero when:
  ///   - `hostNowSeconds` or `ptsSeconds` is non-finite (e.g. an
  ///     invalid CMTime returns NaN from `CMTimeGetSeconds`),
  ///   - the difference would be negative (clock skew or pts in the
  ///     future).
  /// In either case the returned instant equals `nowWall` — better
  /// than projecting the capture into the future, which would make
  /// every cursor sample's elapsed time negative.
  static func captureInstant(
    nowWall: Date,
    hostNowSeconds: Double,
    ptsSeconds: Double
  ) -> Date {
    let age = hostNowSeconds - ptsSeconds
    let safeAge = age.isFinite && age > 0 ? age : 0
    return nowWall.addingTimeInterval(-safeAge)
  }

  /// Convert a wall-clock instant `now` into a video-relative
  /// timestamp in microseconds, given the first frame's capture
  /// instant. Returns `nil` for events that fired before the first
  /// frame — dropping them prevents a cluster of pre-warmup samples
  /// from all collapsing onto t=0, where the playback binary-search
  /// would surface only one of them and the rest would silently
  /// disappear from the trail.
  static func videoMicros(now: Date, since frameStart: Date) -> Int64? {
    let elapsed = now.timeIntervalSince(frameStart)
    guard elapsed >= 0 else { return nil }
    // Round to nearest, not truncate. `Date.timeIntervalSince` returns
    // a Double, and subtractions of host-clock seconds (e.g. 12345.08 -
    // 12345.00) routinely land an ULP below the intended value. Plain
    // Int64 cast then truncates toward zero, giving an off-by-one micro
    // (e.g. 199_999 instead of 200_000) on boundary values.
    return Int64((elapsed * 1_000_000).rounded())
  }
}
