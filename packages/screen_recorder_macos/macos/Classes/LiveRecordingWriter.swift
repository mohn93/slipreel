// packages/screen_recorder_macos/macos/Classes/LiveRecordingWriter.swift
import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Writes a complete H.264 + AAC MP4 file directly during capture.
///
/// Owns an `AVAssetWriter` with two inputs (video and optional audio).
/// Compressed video sample buffers come from `VideoToolboxEncoder`'s output
/// callback; audio sample buffers come from `AudioCaptureManager`. Both are
/// appended in real time as the capture session produces them.
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
      case .cannotAddVideoInput: return "AVAssetWriter would not accept the video input"
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
  private let captureAudio: Bool

  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?

  private var isStarted = false
  private var sessionStartedAt: CMTime?

  /// Set to true once `assetWriter.startWriting()` has been called.
  private var writerActive = false

  // MARK: - Init

  init(outputPath: String, width: Int, height: Int, fps: Int, captureAudio: Bool) {
    self.outputURL = URL(fileURLWithPath: outputPath)
    self.width = width
    self.height = height
    self.fps = fps
    self.captureAudio = captureAudio
  }

  // MARK: - Lifecycle

  /// Configure the AVAssetWriter and prepare it to receive samples.
  /// Call once before any `append*` call.
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

    // Video input — expects already-compressed H.264 sample buffers from VTCompressionSession.
    // Output settings are nil because we're passing through compressed data.
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
    videoInput.expectsMediaDataInRealTime = true
    guard writer.canAdd(videoInput) else {
      throw WriterError.cannotAddVideoInput
    }
    writer.add(videoInput)
    self.videoInput = videoInput

    // Audio input — let the writer encode raw PCM to AAC for us.
    if captureAudio {
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128_000,
      ]
      let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      audioInput.expectsMediaDataInRealTime = true
      guard writer.canAdd(audioInput) else {
        throw WriterError.cannotAddAudioInput
      }
      writer.add(audioInput)
      self.audioInput = audioInput
    }

    self.assetWriter = writer
    self.isStarted = true
  }

  /// Append a compressed video sample. The first append also opens the
  /// session — its presentation time becomes the timeline origin.
  func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    guard isStarted, let writer = assetWriter, let input = videoInput else { return }

    if !writerActive {
      let startedOk = writer.startWriting()
      if !startedOk {
        NSLog("[LiveRecordingWriter] startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        return
      }
      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      writer.startSession(atSourceTime: pts)
      sessionStartedAt = pts
      writerActive = true
    }

    if input.isReadyForMoreMediaData {
      input.append(sampleBuffer)
    } else {
      // Drop. Capture queue depth + VT real-time mode should keep this rare;
      // PerfSampler will report the drop count.
    }
  }

  /// Append a raw audio sample buffer. The writer encodes to AAC.
  func appendAudio(_ sampleBuffer: CMSampleBuffer) {
    guard isStarted, writerActive, let input = audioInput else { return }
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
    audioInput?.markAsFinished()

    if !writerActive {
      // Nothing was ever written; just clean up.
      isStarted = false
      completion(.success(outputURL.path))
      return
    }

    writer.finishWriting { [weak self] in
      guard let self = self else { return }
      defer { self.isStarted = false }
      if writer.status == .completed {
        completion(.success(self.outputURL.path))
      } else {
        completion(.failure(WriterError.finalizeFailed(writer.error)))
      }
    }
  }
}
