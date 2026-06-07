// packages/screen_recorder_macos/macos/Classes/CameraSidecarWriter.swift
import Foundation
import AVFoundation
import CoreMedia

/// Writes the camera webcam track to its own .mov, time-aligned to the screen
/// recording. Modeled on LiveRecordingWriter but with a single H.264-encoded
/// video input (camera frames arrive uncompressed from AVCaptureVideoDataOutput,
/// so the writer compresses them — no manual VideoToolbox stage).
///
/// The session is anchored to the first appended sample. `firstSampleHostSeconds`
/// captures that sample's host-clock time so the plugin can compute the
/// microsecond offset between the camera and screen timelines.
final class CameraSidecarWriter {
  enum WriterError: LocalizedError {
    case alreadyStarted, cannotAddInput, startFailed(Error?), finalizeFailed(Error?)
    var errorDescription: String? {
      switch self {
      case .alreadyStarted: return "CameraSidecarWriter already started"
      case .cannotAddInput: return "AVAssetWriter would not accept the camera input"
      case .startFailed(let e): return "startWriting failed: \(e?.localizedDescription ?? "?")"
      case .finalizeFailed(let e): return "finishWriting failed: \(e?.localizedDescription ?? "?")"
      }
    }
  }

  private let outputURL: URL
  private let width: Int
  private let height: Int

  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var isStarted = false
  private var writerActive = false
  /// Number of appended frames. Read only after the capture session is stopped
  /// AND a `sampleQueue.sync {}` barrier (so no append is in-flight off-queue).
  private(set) var frameCount: Int = 0

  /// Host-clock seconds of the first appended sample's PTS. nil until first frame.
  /// Read only after stop + a `sampleQueue.sync {}` barrier (see frameCount).
  private(set) var firstSampleHostSeconds: Double?

  // Pause/resume — identical semantics to LiveRecordingWriter.
  private var isPaused = false
  private var pauseStart: CMTime?
  private var pausedOffset: CMTime = .zero

  /// Set if startWriting() ever fails, so we stop retrying every frame and the
  /// failure is logged once instead of silently dropping the whole track.
  private var writerStartFailed = false

  private let queue = DispatchQueue(label: "com.slipreel.screen_recorder.camera-writer")

  init(outputPath: String, width: Int, height: Int) {
    self.outputURL = URL(fileURLWithPath: outputPath)
    self.width = width
    self.height = height
  }

  func start() throws {
    try queue.sync {
      guard !isStarted else { throw WriterError.alreadyStarted }
      try? FileManager.default.removeItem(at: outputURL)
      let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
      // No movieFragmentInterval: the camera sidecar is secondary to the primary
      // screen recording (which carries its own crash-resilient fragmentation).
      // A crash loses at most the webcam track, never the screen recording, so
      // fragmenting the .mov here isn't worth the runtime warning it can trigger.

      let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
      ]
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else { throw WriterError.cannotAddInput }
      writer.add(input)

      self.assetWriter = writer
      self.videoInput = input
      self.isStarted = true
    }
  }

  /// Append one camera sample. The first call starts the writer session anchored
  /// at that sample's PTS and records its host-clock time.
  func append(_ sampleBuffer: CMSampleBuffer) {
    queue.sync {
      guard isStarted, let writer = assetWriter, let input = videoInput else { return }
      if isPaused { return }
      let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

      if writerStartFailed { return }
      if !writerActive {
        guard writer.startWriting() else {
          writerStartFailed = true
          NSLog("[CameraSidecarWriter] startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
          return
        }
        writer.startSession(atSourceTime: pts)
        // PTS here is on the host time clock (same as SCStream); record seconds.
        firstSampleHostSeconds = CMTimeGetSeconds(pts)
        writerActive = true
      }

      guard input.isReadyForMoreMediaData else { return }
      let rebased = rebaseSampleBuffer(sampleBuffer) ?? sampleBuffer
      input.append(rebased)
      frameCount += 1
    }
  }

  func stop(completion: @escaping (Result<String, Error>) -> Void) {
    // async (not sync): finishWriting delivers its completion later on
    // AVFoundation's own thread, and async avoids a deadlock if stop() is ever
    // invoked from the writer queue.
    queue.async {
      guard self.isStarted, let writer = self.assetWriter else {
        completion(.success(self.outputURL.path)); return
      }
      if self.isPaused { self.isPaused = false; self.pauseStart = nil }
      self.videoInput?.markAsFinished()
      if !self.writerActive {
        self.isStarted = false
        completion(.success(self.outputURL.path)); return
      }
      let path = self.outputURL.path
      writer.finishWriting {
        writer.status == .completed
          ? completion(.success(path))
          : completion(.failure(WriterError.finalizeFailed(writer.error)))
      }
      self.isStarted = false
    }
  }

  func pause() {
    queue.sync {
      guard isStarted, writerActive, !isPaused else { return }
      isPaused = true
      pauseStart = CMClockGetTime(CMClockGetHostTimeClock())
    }
  }

  func resume() {
    queue.sync {
      guard isStarted, isPaused, let start = pauseStart else {
        isPaused = false; pauseStart = nil; return
      }
      let now = CMClockGetTime(CMClockGetHostTimeClock())
      pausedOffset = CMTimeAdd(pausedOffset, CMTimeSubtract(now, start))
      isPaused = false; pauseStart = nil
    }
  }

  private func rebaseSampleBuffer(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
    if pausedOffset == .zero { return nil }
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    if count == 0 { return nil }
    var timing = Array(repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
    for i in 0..<count {
      timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, pausedOffset)
      if CMTimeCompare(timing[i].decodeTimeStamp, .invalid) != 0 &&
         CMTimeCompare(timing[i].decodeTimeStamp, .indefinite) != 0 {
        timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, pausedOffset)
      }
    }
    var out: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault, sampleBuffer: sb,
      sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out)
    return status == noErr ? out : nil
  }
}
