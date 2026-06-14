// packages/screen_recorder_macos/macos/Classes/CameraCaptureManager.swift
import AVFoundation
import Cocoa
import CoreMedia

/// Captures the webcam during a screen recording. Owns an AVCaptureSession with
/// a video device input and a video-data output; fans each frame to a
/// CameraSidecarWriter (.camera.mov) and a draggable self-view panel.
///
/// Frames carry host-time PTS (same clock as SCStream), so the writer's first
/// sample time aligns with the screen track via a stored offset (computed by the
/// plugin). Capture resolution is capped to 1080p.
final class CameraCaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  struct StopInfo {
    let frameCount: Int
    let width: Int
    let height: Int
    let firstSampleHostSeconds: Double?
    let selfViewX: Double
    let selfViewY: Double
  }

  private let session = AVCaptureSession()
  private let output = AVCaptureVideoDataOutput()
  private let sampleQueue = DispatchQueue(label: "com.slipreel.screen_recorder.camera-capture")

  private var writer: CameraSidecarWriter?
  private var selfView: CameraSelfViewPanel?
  private var outWidth = 0
  private var outHeight = 0

  /// m17: invoked (on main) when the capture session reports a runtime error or
  /// interruption — e.g. the webcam is unplugged mid-recording. Lets the owner
  /// log/surface a non-fatal warning. The screen recording is NOT torn down;
  /// frames captured up to the failure stay in the sidecar (finalized on stop).
  var onRuntimeError: ((String) -> Void)?
  private var observers: [NSObjectProtocol] = []

  /// All connected video capture devices as [{uid,label}] for the picker menu.
  static func availableDevices() -> [[String: String]] {
    var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    if #available(macOS 14.0, *) {
      deviceTypes.append(.external)
    } else {
      deviceTypes.append(.externalUnknown)
    }
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
    return discovery.devices.map { ["uid": $0.uniqueID, "label": $0.localizedName] }
  }

  /// Start capturing [deviceUid] to [outputPath].camera.mov and show the self-view.
  /// Throws if the device can't be resolved or the session can't be configured.
  func start(deviceUid: String, outputPath: String) throws {
    let device: AVCaptureDevice
    if let d = AVCaptureDevice(uniqueID: deviceUid) {
      device = d
    } else if let d = AVCaptureDevice.default(for: .video) {
      device = d
    } else {
      throw NSError(domain: "CameraCaptureManager", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No camera device available"])
    }

    session.beginConfiguration()
    session.sessionPreset = .high
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      session.commitConfiguration()
      throw NSError(domain: "CameraCaptureManager", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
    }
    session.addInput(input)

    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: sampleQueue)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw NSError(domain: "CameraCaptureManager", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add camera output"])
    }
    session.addOutput(output)
    session.commitConfiguration()

    // Resolve capture dimensions (cap to 1080p tall), then create the writer.
    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    var w = Int(dims.width)
    var h = Int(dims.height)
    if h > 1080 {
      let scale = 1080.0 / Double(h)
      w = Int((Double(w) * scale).rounded()) & ~1   // keep even
      h = 1080
    }
    outWidth = max(2, w)
    outHeight = max(2, h)

    let w2 = CameraSidecarWriter(outputPath: outputPath + ".camera.mov",
                                 width: outWidth, height: outHeight)
    try w2.start()
    writer = w2

    installSessionObservers()
    session.startRunning()

    DispatchQueue.main.async {
      let panel = CameraSelfViewPanel(session: self.session)
      panel.show()
      self.selfView = panel
    }
  }

  /// m17: observe runtime errors / interruptions on the capture session so an
  /// unplugged or seized webcam no longer truncates the track silently. We warn
  /// and keep recording screen-only; frames captured before the failure stay in
  /// the sidecar (finalized on stop()).
  private func installSessionObservers() {
    let center = NotificationCenter.default
    let runtimeError = center.addObserver(
      forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
    ) { [weak self] note in
      guard let self = self else { return }
      let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
      let message = err?.localizedDescription ?? "camera capture error"
      NSLog("[CameraCaptureManager] runtime error: %@", message)
      self.onRuntimeError?(message)
    }
    let interrupted = center.addObserver(
      forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main
    ) { [weak self] _ in
      NSLog("[CameraCaptureManager] capture session interrupted")
      self?.onRuntimeError?("camera capture interrupted")
    }
    observers = [runtimeError, interrupted]
  }

  private func removeSessionObservers() {
    let center = NotificationCenter.default
    for o in observers { center.removeObserver(o) }
    observers.removeAll()
  }

  func pause(at hostTime: CMTime? = nil) { writer?.pause(at: hostTime) }
  func resume(at hostTime: CMTime? = nil) { writer?.resume(at: hostTime) }

  /// Stop the session + self-view, finalize the writer, and return capture info.
  func stop(completion: @escaping (StopInfo) -> Void) {
    removeSessionObservers()
    session.stopRunning()
    // Barrier: drain any in-flight captureOutput callbacks (which call
    // writer.append on this queue) so frameCount/firstSampleHostSeconds are
    // final before we read them.
    sampleQueue.sync(execute: {} as () -> Void)
    let captured = writer
    let frames = captured?.frameCount ?? 0
    let firstHost = captured?.firstSampleHostSeconds
    let w = outWidth, h = outHeight

    DispatchQueue.main.async(execute: DispatchWorkItem {
      let center = self.selfView?.normalizedCenter() ?? (x: 0.82, y: 0.82)
      self.selfView?.hide()
      self.selfView = nil
      captured?.stop { _ in
        completion(StopInfo(frameCount: frames, width: w, height: h,
                            firstSampleHostSeconds: firstHost,
                            selfViewX: center.x, selfViewY: center.y))
      }
    })
  }

  // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    writer?.append(sampleBuffer)
  }
}
