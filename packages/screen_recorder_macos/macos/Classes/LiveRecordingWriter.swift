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
    case assetWriterCreateFailed(Error)
    case cannotAddVideoInput
    case cannotAddAudioInput
    case startWritingFailed(Error?)
    case finalizeFailed(Error?)

    var errorDescription: String? {
      switch self {
      case .alreadyStarted: return "LiveRecordingWriter is already started"
      case .notStarted: return "LiveRecordingWriter is not started"
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

  /// Number of times appendVideo was called.
  private(set) var appendVideoCallCount: Int = 0
  /// Number of times a sample was successfully appended (input was ready).
  private(set) var appendVideoAcceptedCount: Int = 0
  /// Number of times a sample was dropped because input was not ready.
  private(set) var appendVideoNotReadyCount: Int = 0

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
    guard !isStarted else { throw WriterError.alreadyStarted }

    // Remove any pre-existing file at the path
    try? FileManager.default.removeItem(at: outputURL)

    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    } catch {
      throw WriterError.assetWriterCreateFailed(error)
    }

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
    appendVideoCallCount += 1
    guard isStarted, let _ = assetWriter else { return }

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
      input.append(sampleBuffer)
      appendVideoAcceptedCount += 1
    } else {
      appendVideoNotReadyCount += 1
      // Drop. Capture queue depth + VT real-time mode should keep this rare;
      // PerfSampler will report the drop count.
    }
  }

  /// Append a raw audio sample buffer for the given track role. The writer encodes to AAC.
  /// Audio arriving before the video input is ready (writerActive == false) is
  /// silently dropped; the session start time is anchored to the first video
  /// sample's PTS so pre-session audio is outside the timeline anyway.
  func appendAudio(_ sampleBuffer: CMSampleBuffer, role: AudioTrackRole) {
    guard isStarted, writerActive, let input = audioInputs[role] else { return }
    if input.isReadyForMoreMediaData {
      input.append(sampleBuffer)
    }
  }

  /// Finish writing and return the output path. Safe to call once.
  func stop(completion: @escaping (Result<String, Error>) -> Void) {
    guard isStarted, let writer = assetWriter else {
      completion(.failure(WriterError.notStarted))
      return
    }

    videoInput?.markAsFinished()
    audioInputs.values.forEach { $0.markAsFinished() }

    if !writerActive {
      // Nothing was ever written; just clean up.
      isStarted = false
      completion(.success(outputURL.path))
      return
    }

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
  }
}
