// packages/screen_recorder_macos/macos/Classes/DeviceCaptureManager.swift
import AVFoundation

/// Captures a USB iOS device's screen (+ optional audio) via AVCaptureSession.
/// Supplies RAW video frames and RAW audio sample buffers via callbacks; the
/// plugin wires those into the shared VideoToolboxEncoder + LiveRecordingWriter
/// (same path as screen capture).
final class DeviceCaptureManager: NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate {

  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let audioOutput = AVCaptureAudioDataOutput()
  private let videoQueue = DispatchQueue(label: "com.slipreel.device-capture.video")
  private let audioQueue = DispatchQueue(label: "com.slipreel.device-capture.audio")

  var onVideoFrame: ((CMSampleBuffer) -> Void)?
  var onAudioSample: ((CMSampleBuffer) -> Void)?
  var onDisconnect: (() -> Void)?

  private(set) var width = 0
  private(set) var height = 0
  private(set) var nominalFps = 30
  private var captureDevice: AVCaptureDevice?

  /// Number of VIDEO frames delivered to `onVideoFrame` so far. The plugin
  /// reads this in its Stop path to decide whether the writer ever started a
  /// session (zero frames ⇒ AVAssetWriter session never opened). Mutated only
  /// from `videoQueue` (inside `captureOutput`); read with `videoQueue.sync`.
  private var videoFrameCount = 0
  /// One-shot guard so the "first frame arrived" diagnostic logs exactly once.
  private var loggedFirstVideoFrame = false
  /// Guards `stop()` against re-entrancy / double-invocation (e.g. a Stop racing
  /// a disconnect). Without this, calling `videoQueue.sync {}` a second time
  /// after the session already tore down is wasteful, and calling `stop()` from
  /// the capture queue itself would deadlock.
  private var stopped = false

  /// Total VIDEO frames delivered so far. Read by the plugin's Stop path to
  /// distinguish a real recording from a zero-frame (never-started-session)
  /// device capture. Thread-safe.
  var deliveredVideoFrameCount: Int {
    return videoQueue.sync { videoFrameCount }
  }

  // NEEDS DEVICE VERIFICATION (#device-capture):
  // The iPhone *screen* device is a MUXED AVCaptureDevice (audio+video in one
  // device, name WITHOUT "Camera"). HYPOTHESIS: AVFoundation may not deliver
  // VIDEO frames from a muxed device through a plain AVCaptureVideoDataOutput,
  // so `onVideoFrame` never fires → the writer's lazy session never opens →
  // Stop has nothing to finalize. The changes below are ADDITIVE diagnostics +
  // guards to (a) make video frames more likely to flow and (b) make the
  // zero-frame case observable in device-side logs. They do NOT rip out the
  // existing video-output structure. This whole muxed path must be verified
  // with a real iPhone connected over USB — it could not be runtime-verified
  // on the build machine (no device; `flutter build macos` is broken here).
  func start(deviceUid: String, captureAudio: Bool) throws {
    guard let device = AVCaptureDevice(uniqueID: deviceUid) else {
      throw NSError(domain: "DeviceCaptureManager", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Device not found (unplugged or untrusted)"])
    }
    captureDevice = device

    // Diagnostic: dump the device's media types + formats so device-side logs
    // confirm whether the selected device actually advertises a video track
    // (a muxed device reports BOTH .muxed and/or .video + .audio).
    NSLog("[DeviceCaptureManager] start device='%@' uid='%@' hasMuxed=%@ hasVideo=%@ hasAudio=%@ formats=%d",
          device.localizedName, deviceUid,
          device.hasMediaType(.muxed) ? "YES" : "no",
          device.hasMediaType(.video) ? "YES" : "no",
          device.hasMediaType(.audio) ? "YES" : "no",
          device.formats.count)

    session.beginConfiguration()
    // A muxed device may not support the `.high` preset; committing an
    // unsupported preset can yield a running-but-frameless session. Pick the
    // first preset the device actually accepts, guarded by `canSetSessionPreset`
    // so we never force an unsupported one. (`.inputPriority` — "let the device
    // pick" — is NOT available on macOS, so we fall back through concrete
    // presets instead.)
    let presetCandidates: [AVCaptureSession.Preset] = [.high, .medium, .low]
    if let preset = presetCandidates.first(where: { session.canSetSessionPreset($0) }) {
      if preset != .high {
        NSLog("[DeviceCaptureManager] .high preset unsupported; using %@", preset.rawValue)
      }
      session.sessionPreset = preset
    } else {
      NSLog("[DeviceCaptureManager] no candidate preset settable; leaving session default preset")
    }

    let videoInput = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(videoInput) else {
      session.commitConfiguration()
      throw NSError(domain: "DeviceCaptureManager", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Cannot add device video input"])
    }
    session.addInput(videoInput)

    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
    guard session.canAddOutput(videoOutput) else {
      session.commitConfiguration()
      throw NSError(domain: "DeviceCaptureManager", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Cannot add device video output"])
    }
    session.addOutput(videoOutput)

    // Diagnostic: a muxed device that does NOT demux into the video-data output
    // will have a nil .video connection here — which would fully explain zero
    // frames. Log it loudly so device-side logs make the cause obvious.
    if videoOutput.connection(with: .video) == nil {
      NSLog("[DeviceCaptureManager] WARNING: videoOutput has NO .video connection after addOutput — muxed device likely will NOT deliver demuxed video frames (#device-capture)")
    } else {
      NSLog("[DeviceCaptureManager] videoOutput .video connection is present")
    }

    if captureAudio, session.canAddOutput(audioOutput) {
      audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
      session.addOutput(audioOutput)
    }
    session.commitConfiguration()

    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    width = Int(dims.width)
    height = Int(dims.height)
    let fr = device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30
    nominalFps = max(1, Int(fr.rounded()))
    NSLog("[DeviceCaptureManager] activeFormat dims=%dx%d nominalFps=%d", width, height, nominalFps)

    NotificationCenter.default.addObserver(
      self, selector: #selector(deviceDisconnected(_:)),
      name: .AVCaptureDeviceWasDisconnected, object: device)

    session.startRunning()
  }

  @objc private func deviceDisconnected(_ note: Notification) { onDisconnect?() }

  /// Tear down the capture session. Safe to call multiple times and from any
  /// non-capture thread. The `videoQueue.sync {}` / `audioQueue.sync {}` drains
  /// flush any in-flight delegate callback so no frame arrives after the caller
  /// proceeds to finalize the encoder/writer.
  ///
  /// IMPORTANT: must NOT be called from `videoQueue`/`audioQueue` themselves
  /// (the `.sync` would deadlock). The plugin only calls this from its Stop /
  /// teardown path on a Task/main context, never from a capture callback.
  func stop() {
    if stopped { return }
    stopped = true
    NotificationCenter.default.removeObserver(
      self, name: .AVCaptureDeviceWasDisconnected, object: captureDevice)
    // Drop callbacks BEFORE stopping the session so any frame still in flight on
    // the capture queues becomes a no-op (defense-in-depth; the plugin also
    // nils these before calling stop()).
    onVideoFrame = nil
    onAudioSample = nil
    onDisconnect = nil
    session.stopRunning()
    videoQueue.sync {}
    audioQueue.sync {}
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    if output === videoOutput {
      videoFrameCount += 1  // on videoQueue
      if !loggedFirstVideoFrame {
        loggedFirstVideoFrame = true
        NSLog("[DeviceCaptureManager] first VIDEO frame delivered from device — muxed demux IS working (#device-capture)")
      }
      onVideoFrame?(sampleBuffer)
    } else if output === audioOutput {
      onAudioSample?(sampleBuffer)
    }
  }
}
