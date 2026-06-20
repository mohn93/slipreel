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

  func start(deviceUid: String, captureAudio: Bool) throws {
    guard let device = AVCaptureDevice(uniqueID: deviceUid) else {
      throw NSError(domain: "DeviceCaptureManager", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Device not found (unplugged or untrusted)"])
    }
    captureDevice = device
    session.beginConfiguration()
    session.sessionPreset = .high

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

    NotificationCenter.default.addObserver(
      self, selector: #selector(deviceDisconnected(_:)),
      name: .AVCaptureDeviceWasDisconnected, object: device)

    session.startRunning()
  }

  @objc private func deviceDisconnected(_ note: Notification) { onDisconnect?() }

  func stop() {
    NotificationCenter.default.removeObserver(
      self, name: .AVCaptureDeviceWasDisconnected, object: captureDevice)
    session.stopRunning()
    videoQueue.sync {}
    audioQueue.sync {}
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    if output === videoOutput { onVideoFrame?(sampleBuffer) }
    else if output === audioOutput { onAudioSample?(sampleBuffer) }
  }
}
