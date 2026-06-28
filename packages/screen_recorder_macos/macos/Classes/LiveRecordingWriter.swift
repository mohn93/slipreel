// packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift
import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

enum AudioTrackRole: String { case microphone, system }

/// Writes a complete H.264 + AAC MP4 file directly during capture.
///
/// Owns an `AVAssetWriter` with two inputs (video and optional audio).
/// Compressed video sample buffers come from `VideoToolboxEncoder`'s output
/// callback; audio sample buffers come from `AudioCaptureManager`. Both are
/// appended in real time as the capture session produces them.
///
/// The video input is added lazily on the first compressed sample so that we
/// can pass `sourceFormatHint` (derived from that sample's format description).
/// Without this hint, `AVAssetWriter.canAdd(_:)` returns false for passthrough
/// (nil outputSettings) inputs — the root cause of LIVE_START_FAILED.
///
/// On `stop()` the writer flushes pending samples, finalizes the file, and
/// returns the absolute path.
class LiveRecordingWriter {
  // MARK: - Errors

  enum WriterError: LocalizedError {
    case alreadyStarted
    case notStarted
    case noFramesWritten
    case assetWriterCreateFailed(Error)
    case cannotAddVideoInput
    case cannotAddAudioInput
    case startWritingFailed(Error?)
    case finalizeFailed(Error?)

    var errorDescription: String? {
      switch self {
      case .alreadyStarted: return "LiveRecordingWriter is already started"
      case .notStarted: return "LiveRecordingWriter is not started"
      case .noFramesWritten: return "No frames captured from device"
      case .assetWriterCreateFailed(let e): return "Failed to create AVAssetWriter: \(e.localizedDescription)"
      case .cannotAddVideoInput: return "AVAssetWriter would not accept the video input (even with sourceFormatHint)"
      case .cannotAddAudioInput: return "AVAssetWriter would not accept the audio input"
      case .startWritingFailed(let e): return "AVAssetWriter.startWriting failed: \(e?.localizedDescription ?? "unknown")"
      case .finalizeFailed(let e): return "AVAssetWriter.finishWriting failed: \(e?.localizedDescription ?? "unknown")"
      }
    }
  }

  // MARK: - Properties

  private let outputURL: URL
  private let width: Int
  private let height: Int
  private let fps: Int
  private let audioTracks: [AudioTrackRole]

  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInputs: [AudioTrackRole: AVAssetWriterInput] = [:]

  private var isStarted = false
  private var sessionStartedAt: CMTime?

  /// Set to true once `assetWriter.startWriting()` and `startSession` have been called.
  private var writerActive = false

  /// True when pause() has been called and not yet matched by resume().
  /// Sample buffers are dropped while this is true.
  private var isPaused = false

  /// Host-clock time when pause() was called. Set on pause, cleared on resume.
  private var pauseStart: CMTime?

  /// Accumulated paused duration. Subtracted from every sample's PTS so the
  /// output timeline has no gap.
  private var pausedOffset: CMTime = .zero

  /// Number of times appendVideo was called.
  private(set) var appendVideoCallCount: Int = 0
  /// Number of times a sample was successfully appended (input was ready).
  private(set) var appendVideoAcceptedCount: Int = 0
  /// Number of times a sample was dropped because input was not ready.
  private(set) var appendVideoNotReadyCount: Int = 0

  /// Serializes all access to the AVAssetWriter + inputs + state. appendVideo
  /// (VideoToolbox queue), appendAudio (audio queues), and start/stop (Task
  /// threads) all funnel through here — Apple requires serialized access to a
  /// single AVAssetWriter.
  private let writerQueue = DispatchQueue(label: "com.slipreel.screen_recorder.writer")

  // MARK: - Init

  init(outputPath: String, width: Int, height: Int, fps: Int, audioTracks: [AudioTrackRole]) {
    self.outputURL = URL(fileURLWithPath: outputPath)
    self.width = width
    self.height = height
    self.fps = fps
    self.audioTracks = audioTracks
  }

  // MARK: - Lifecycle

  /// Configure the AVAssetWriter and the audio input (if enabled).
  /// The video input is NOT created here — it is deferred to the first
  /// `appendVideo` call so that a `sourceFormatHint` can be extracted from
  /// the first compressed sample. Call once before any `append*` call.
  func start() throws {
    try writerQueue.sync {
      guard !isStarted else { throw WriterError.alreadyStarted }

      // Remove any pre-existing file at the path
      try? FileManager.default.removeItem(at: outputURL)

      let writer: AVAssetWriter
      do {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
      } catch {
        throw WriterError.assetWriterCreateFailed(error)
      }

      // Crash resilience: emit a self-contained moof+mdat fragment every 5 s.
      // On a process kill, the file on disk is still playable up to the last
      // complete fragment. (Sub-project C.)
      writer.movieFragmentInterval = CMTimeMakeWithSeconds(5.0, preferredTimescale: 600)

      // Audio inputs — one per requested track role.
      // This uses an explicit outputSettings dict so canAdd() succeeds immediately.
      for role in audioTracks {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings(for: role))
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
          throw WriterError.cannotAddAudioInput
        }
        writer.add(input)
        audioInputs[role] = input
      }

      // Video input is intentionally NOT added here. See addVideoInputAndStartSession(_:pts:).

      self.assetWriter = writer
      self.isStarted = true
    }
  }

  // MARK: - Private helpers

  private static func audioSettings(for role: AudioTrackRole) -> [String: Any] {
    let channels = (role == .system) ? 2 : 1
    return [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48000,
      AVNumberOfChannelsKey: channels,
      AVEncoderBitRateKey: 128_000,
    ]
  }

  /// Add the video input using the format description extracted from the first
  /// compressed sample, then start writing and open the AVAssetWriter session.
  ///
  /// Passing `sourceFormatHint` is required when `outputSettings` is nil
  /// (passthrough mode). Without it, `canAdd()` always returns false.
  private func addVideoInputAndStartSession(formatDescription: CMFormatDescription, pts: CMTime) throws {
    guard let writer = assetWriter else { return }

    // Passthrough: nil outputSettings + sourceFormatHint from the first sample.
    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: nil,
      sourceFormatHint: formatDescription
    )
    videoInput.expectsMediaDataInRealTime = true

    guard writer.canAdd(videoInput) else {
      throw WriterError.cannotAddVideoInput
    }
    writer.add(videoInput)
    self.videoInput = videoInput

    let startedOk = writer.startWriting()
    if !startedOk {
      throw WriterError.startWritingFailed(writer.error)
    }

    writer.startSession(atSourceTime: pts)
    sessionStartedAt = pts
    writerActive = true
  }

  // MARK: - Sample appending

  /// Append a compressed video sample. The first call lazily adds the video
  /// input (with a format-description hint) and starts the write session.
  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    writerQueue.sync {
      appendVideoCallCount += 1
      guard isStarted, let _ = assetWriter else { return }
      if isPaused { return }

      if !writerActive {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
          return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        do {
          try addVideoInputAndStartSession(formatDescription: formatDescription, pts: pts)
        } catch {
          return
        }
      }

      guard let input = videoInput else { return }
      if input.isReadyForMoreMediaData {
        let rebased = rebaseSampleBuffer(sampleBuffer)
        input.append(rebased ?? sampleBuffer)
        appendVideoAcceptedCount += 1
      } else {
        appendVideoNotReadyCount += 1
      }
    }
  }

  /// Append a raw audio sample buffer for the given track role. The writer encodes to AAC.
  /// Audio arriving before the video input is ready (writerActive == false) is
  /// silently dropped; the session start time is anchored to the first video
  /// sample's PTS so pre-session audio is outside the timeline anyway.
  func appendAudio(_ sampleBuffer: CMSampleBuffer, role: AudioTrackRole) {
    writerQueue.sync {
      guard isStarted, writerActive, let input = audioInputs[role] else { return }
      if isPaused { return }
      if input.isReadyForMoreMediaData {
        let rebased = rebaseSampleBuffer(sampleBuffer)
        input.append(rebased ?? sampleBuffer)
      }
    }
  }

  /// Finish writing and return the output path. Safe to call once.
  func stop(completion: @escaping (Result<String, Error>) -> Void) {
    // Result computed synchronously for the early-exit cases; for the normal
    // finalize path the completion is invoked later by `finishWriting`.
    enum SyncResult {
      case notStarted
      case nothingWritten
      case finalizing
    }

    let syncResult: SyncResult = writerQueue.sync {
      guard isStarted, let writer = assetWriter else {
        return .notStarted
      }

      // Unpause before finalizing so writer drains its queues.
      if isPaused {
        isPaused = false
        pauseStart = nil
      }

      if !writerActive {
        // Nothing was ever written: the lazy AVAssetWriter session never opened
        // because no first video sample arrived (e.g. a muxed device that never
        // delivered demuxed video frames — see DeviceCaptureManager's muxed
        // note; also reproduces when an iPhone/iPad source is recorded with its
        // screen off so no frames are produced). Clean up and surface a clear
        // error rather than returning a phantom success path that points at a
        // missing/empty file (which the Dart side would then trip over when it
        // stats the file). This path is FULLY synchronous — it always fires the
        // completion below — so Stop can never wedge waiting on a finalize that
        // has nothing to finish.
        //
        // CRITICAL: this guard must run BEFORE markAsFinished() below. Calling
        // markAsFinished() on an input whose AVAssetWriter never left .unknown
        // (startWriting()/startSession() deferred to the first video sample)
        // throws an uncatchable Obj-C exception → SIGABRT.
        isStarted = false
        return .nothingWritten
      }

      // Safe only now that writerActive == true (writer.status == .writing).
      videoInput?.markAsFinished()
      audioInputs.values.forEach { $0.markAsFinished() }

      let outputPath = outputURL.path
      writer.finishWriting {
        let status = writer.status
        if status == .completed {
          completion(.success(outputPath))
        } else {
          completion(.failure(WriterError.finalizeFailed(writer.error)))
        }
      }
      isStarted = false
      return .finalizing
    }

    // Fire the completion for the early-exit cases OUTSIDE the queue so we never
    // block the serial queue on the caller. The `.finalizing` case's completion
    // is delivered later by `finishWriting` on AVFoundation's thread.
    switch syncResult {
    case .notStarted:
      completion(.failure(WriterError.notStarted))
    case .nothingWritten:
      completion(.failure(WriterError.noFramesWritten))
    case .finalizing:
      break
    }
  }

  /// Pause appending sample buffers. Idempotent.
  ///
  /// Requires `writerActive` (the AVAssetWriter session is open at a known
  /// source-time). If pause arrives before the first compressed frame opens
  /// the session, this is a no-op — pausing nothing-yet-captured has no
  /// observable effect, and skipping it avoids a broken state where the
  /// rebase offset accumulates before any session start exists.
  /// nit: accepts a host-clock timestamp so the screen and camera writers can
  /// share ONE read per pause/resume edge instead of each sampling the clock
  /// independently (which drifts A/V sub-ms per cycle). Falls back to its own
  /// read when called without one.
  func pause(at hostTime: CMTime? = nil) {
    writerQueue.sync {
      guard isStarted, writerActive, !isPaused else { return }
      isPaused = true
      pauseStart = hostTime ?? CMClockGetTime(CMClockGetHostTimeClock())
    }
  }

  /// Resume appending. Adds the elapsed paused duration to `pausedOffset` so
  /// subsequent samples have their PTS rebased seamlessly. Idempotent.
  func resume(at hostTime: CMTime? = nil) {
    writerQueue.sync {
      guard isStarted, isPaused, let start = pauseStart else {
        isPaused = false
        pauseStart = nil
        return
      }
      let now = hostTime ?? CMClockGetTime(CMClockGetHostTimeClock())
      pausedOffset = CMTimeAdd(pausedOffset, CMTimeSubtract(now, start))
      isPaused = false
      pauseStart = nil
    }
  }

  /// Returns a new `CMSampleBuffer` with its PTS shifted back by `pausedOffset`
  /// so the output timeline excludes paused intervals. Returns `nil` if the
  /// offset is zero or the buffer can't be rewritten (caller falls back to
  /// the original sample).
  private func rebaseSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
    if pausedOffset == .zero { return nil }
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    if count == 0 { return nil }
    var timing = Array(repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(
      sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
    for i in 0..<count {
      timing[i].presentationTimeStamp =
        CMTimeSubtract(timing[i].presentationTimeStamp, pausedOffset)
      if CMTimeCompare(timing[i].decodeTimeStamp, .invalid) != 0 &&
         CMTimeCompare(timing[i].decodeTimeStamp, .indefinite) != 0 {
        timing[i].decodeTimeStamp =
          CMTimeSubtract(timing[i].decodeTimeStamp, pausedOffset)
      }
    }
    var rebased: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sampleBuffer,
      sampleTimingEntryCount: count,
      sampleTimingArray: &timing,
      sampleBufferOut: &rebased)
    return status == noErr ? rebased : nil
  }
}
