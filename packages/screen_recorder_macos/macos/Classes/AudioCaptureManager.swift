import Foundation
import AVFoundation
import CoreAudio
import CoreMedia

/// Manages audio capture using AVAudioEngine
class AudioCaptureManager: NSObject {
  // MARK: - Properties

  private var audioEngine: AVAudioEngine?
  private var inputNode: AVAudioInputNode?
  private var isCapturing = false
  private var currentFormat: AVAudioFormat?

  // Callback for audio data
  var onAudioReceived: ((Data, Int64) -> Void)?
  var onError: ((Error) -> Void)?

  // NEW: raw CMSampleBuffer for the live writer path. Either or both
  // callbacks can be set; both are invoked per buffer.
  var onSampleBufferReceived: ((CMSampleBuffer) -> Void)?

  // Audio format properties
  var sampleRate: Double {
    return currentFormat?.sampleRate ?? 48000.0
  }

  var channelCount: Int {
    return Int(currentFormat?.channelCount ?? 1)
  }

  // MARK: - Permission Handling

  /// Check if microphone permission is granted
  func checkMicrophonePermission() -> Bool {
    if #available(macOS 10.14, *) {
      let status = AVCaptureDevice.authorizationStatus(for: .audio)
      return status == .authorized
    }
    return true
  }

  /// Request microphone permission
  func requestMicrophonePermission() async -> Bool {
    if #available(macOS 10.14, *) {
      return await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          continuation.resume(returning: granted)
        }
      }
    }
    return true
  }

  // MARK: - Audio Capture

  /// Start capturing audio
  /// - Parameters:
  ///   - includeMicrophone: Whether to capture microphone input
  ///   - includeSystem: Whether to capture system audio (not yet supported on macOS)
  func startCapture(includeMicrophone: Bool, includeSystem: Bool) throws {
    guard !isCapturing else {
      throw AudioCaptureError.alreadyCapturing
    }

    // Check microphone permission
    if includeMicrophone && !checkMicrophonePermission() {
      throw AudioCaptureError.permissionDenied
    }

    // Create audio engine
    audioEngine = AVAudioEngine()
    guard let engine = audioEngine else {
      throw AudioCaptureError.engineCreationFailed
    }

    // Note: System audio capture on macOS requires ScreenCaptureKit audio
    // For now, we'll focus on microphone input
    if includeMicrophone {
      try setupMicrophoneCapture(engine: engine)
    }

    // Start the engine
    try engine.start()
    isCapturing = true
  }

  private func setupMicrophoneCapture(engine: AVAudioEngine) throws {
    inputNode = engine.inputNode

    guard let input = inputNode else {
      throw AudioCaptureError.noInputDevice
    }

    // Configure format - use hardware format for best compatibility
    let format = input.outputFormat(forBus: 0)
    currentFormat = format

    // Install tap to capture audio
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
      self?.processAudioBuffer(buffer, time: time)
    }
  }

  private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
    guard let channelData = buffer.floatChannelData else { return }

    let channelCount = Int(buffer.format.channelCount)
    let frameLength = Int(buffer.frameLength)

    // Convert float samples to Int16 PCM
    var pcmData = Data()
    pcmData.reserveCapacity(frameLength * channelCount * 2) // 2 bytes per Int16

    for frame in 0..<frameLength {
      for channel in 0..<channelCount {
        let sample = channelData[channel][frame]
        // Clamp and convert to Int16
        let clamped = max(-1.0, min(1.0, sample))
        let int16Value = Int16(clamped * 32767.0)

        // Append as little-endian bytes
        withUnsafeBytes(of: int16Value.littleEndian) { bytes in
          pcmData.append(contentsOf: bytes)
        }
      }
    }

    // Get timestamp in microseconds - convert from Mach absolute time
    let timestamp = time.hostTime
    var timebaseInfo = mach_timebase_info()
    mach_timebase_info(&timebaseInfo)
    let nanoseconds = timestamp * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    let timestampMicros = Int64(nanoseconds / 1000)

    // Send audio data via callback
    onAudioReceived?(pcmData, timestampMicros)

    // Forward as CMSampleBuffer for the AVAssetWriter path.
    if let onBuf = onSampleBufferReceived,
       let sampleBuffer = makeSampleBuffer(from: buffer, time: time) {
      onBuf(sampleBuffer)
    }
  }

  /// Start capturing a specific microphone device with optional voice
  /// processing. [deviceUid] nil → system default input. Falls back to the
  /// default input if the UID no longer resolves.
  func startMicrophoneCapture(deviceUid: String?, reduceNoise: Bool, disableAgc: Bool) throws {
    guard !isCapturing else { throw AudioCaptureError.alreadyCapturing }
    guard checkMicrophonePermission() else { throw AudioCaptureError.permissionDenied }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    do {
      // Select the chosen device (falls back to default if the UID is gone).
      if let uid = deviceUid, let devID = AudioDeviceCatalog.deviceID(forUID: uid) {
        try input.auAudioUnit.setDeviceID(devID)
      }
      // Noise suppression + level normalization via voice processing.
      if reduceNoise {
        try input.setVoiceProcessingEnabled(true)
        if #available(macOS 14.0, *) {
          input.isVoiceProcessingAGCEnabled = !disableAgc
        }
      }
      let format = input.outputFormat(forBus: 0)
      input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
        self?.processAudioBuffer(buffer, time: time)
      }
      try engine.start()

      // Commit state only after everything succeeded.
      audioEngine = engine
      inputNode = input
      currentFormat = format
      isCapturing = true
    } catch {
      input.removeTap(onBus: 0) // safe no-op if no tap was installed
      engine.stop()
      throw error
    }
  }

  /// Stop capturing audio
  func stopCapture() {
    guard isCapturing else { return }

    // Remove tap
    inputNode?.removeTap(onBus: 0)

    // Stop engine
    audioEngine?.stop()
    audioEngine = nil
    inputNode = nil
    currentFormat = nil

    isCapturing = false
  }

  /// Check if currently capturing
  func isCaptureActive() -> Bool {
    return isCapturing
  }

  private func makeSampleBuffer(from buffer: AVAudioPCMBuffer, time: AVAudioTime) -> CMSampleBuffer? {
    guard let formatDescription = buffer.format.streamDescription.cmFormatDescription() else {
      return nil
    }

    var sampleBuffer: CMSampleBuffer?
    let timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
      presentationTimeStamp: CMTime(value: CMTimeValue(time.sampleTime), timescale: CMTimeScale(buffer.format.sampleRate)),
      decodeTimeStamp: .invalid
    )

    let status = CMAudioSampleBufferCreateWithPacketDescriptions(
      allocator: kCFAllocatorDefault,
      dataBuffer: nil,
      dataReady: false,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleCount: CMItemCount(buffer.frameLength),
      presentationTimeStamp: timing.presentationTimeStamp,
      packetDescriptions: nil,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sb = sampleBuffer else { return nil }

    let setDataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
      sb,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      bufferList: buffer.audioBufferList
    )
    guard setDataStatus == noErr else { return nil }

    return sb
  }
}

// MARK: - Error Types

enum AudioCaptureError: LocalizedError {
  case permissionDenied
  case alreadyCapturing
  case notCapturing
  case engineCreationFailed
  case noInputDevice
  case systemAudioNotSupported

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      return "Microphone permission denied. Please grant permission in System Preferences > Privacy & Security > Microphone."
    case .alreadyCapturing:
      return "Audio capture is already in progress."
    case .notCapturing:
      return "No audio capture session is active."
    case .engineCreationFailed:
      return "Failed to create audio engine."
    case .noInputDevice:
      return "No audio input device found."
    case .systemAudioNotSupported:
      return "System audio capture is not yet supported. Use ScreenCaptureKit for system audio."
    }
  }
}

fileprivate extension UnsafePointer where Pointee == AudioStreamBasicDescription {
  func cmFormatDescription() -> CMAudioFormatDescription? {
    var asbd = self.pointee
    var fd: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &fd
    )
    return status == noErr ? fd : nil
  }
}
