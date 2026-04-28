import Cocoa
import FlutterMacOS
import CoreMedia
import CoreVideo

public class ScreenRecorderMacosPlugin: NSObject, FlutterPlugin {
  private var recordingChannel: FlutterMethodChannel?
  private var captureManager: ScreenCaptureManager?
  private var audioCaptureManager: AudioCaptureManager?
  private var frameStreamHandler: FrameStreamHandler?
  private var audioStreamHandler: AudioStreamHandler?
  private var cursorStreamHandler: CursorStreamHandler?
  private var cursorTracker: CursorTracker?

  // NEW: Live recording state.
  private var liveWriter: LiveRecordingWriter?
  private var liveEncoder: VideoToolboxEncoder?
  private var perfSampler: PerfSampler?
  private var liveStartTime: Date?
  private var liveFrameCount: Int = 0

  public static func register(with registrar: FlutterPluginRegistrar) {
    // Main method channel for recording control
    let recordingChannel = FlutterMethodChannel(
      name: "com.screenflow_studio.screen_recorder/recording",
      binaryMessenger: registrar.messenger
    )

    let instance = ScreenRecorderMacosPlugin()
    instance.recordingChannel = recordingChannel
    registrar.addMethodCallDelegate(instance, channel: recordingChannel)

    // Event channel for video frames
    let framesChannel = FlutterEventChannel(
      name: "com.screenflow_studio.screen_recorder/frames",
      binaryMessenger: registrar.messenger
    )
    instance.frameStreamHandler = FrameStreamHandler()
    framesChannel.setStreamHandler(instance.frameStreamHandler)

    // Event channel for audio samples
    let audioChannel = FlutterEventChannel(
      name: "com.screenflow_studio.screen_recorder/audio",
      binaryMessenger: registrar.messenger
    )
    instance.audioStreamHandler = AudioStreamHandler()
    audioChannel.setStreamHandler(instance.audioStreamHandler)

    // Event channel for cursor tracking
    let cursorChannel = FlutterEventChannel(
      name: "com.screenflow_studio.screen_recorder/cursor",
      binaryMessenger: registrar.messenger
    )
    instance.cursorStreamHandler = CursorStreamHandler()
    cursorChannel.setStreamHandler(instance.cursorStreamHandler)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getAvailableScreens":
      getAvailableScreens(result: result)
    case "getAvailableWindows":
      getAvailableWindows(result: result)
    case "getAudioDevices":
      getAudioDevices(result: result)
    case "startRecording":
      startRecording(call: call, result: result)
    case "stopRecording":
      stopRecording(result: result)
    case "startLiveRecording":
      startLiveRecording(call: call, result: result)
    case "stopLiveRecording":
      stopLiveRecording(result: result)
    case "pauseRecording":
      pauseRecording(result: result)
    case "resumeRecording":
      resumeRecording(result: result)
    case "requestPermissions":
      requestPermissions(result: result)
    case "checkPermissions":
      checkPermissions(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Discovery Methods

  private func getAvailableScreens(result: @escaping FlutterResult) {
    Task {
      do {
        let manager = ScreenCaptureManager()
        let displays = try await manager.getAvailableDisplays()
        result(displays)
      } catch {
        result(FlutterError(
          code: "DISCOVERY_FAILED",
          message: "Failed to get available screens: \(error.localizedDescription)",
          details: nil
        ))
      }
    }
  }

  private func getAvailableWindows(result: @escaping FlutterResult) {
    Task {
      do {
        let manager = ScreenCaptureManager()
        let windows = try await manager.getAvailableWindows()
        result(windows)
      } catch {
        result(FlutterError(
          code: "DISCOVERY_FAILED",
          message: "Failed to get available windows: \(error.localizedDescription)",
          details: nil
        ))
      }
    }
  }

  private func getAudioDevices(result: @escaping FlutterResult) {
    // TODO: Implement in Phase 2
    result([])
  }

  // MARK: - Recording Control

  private func startRecording(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let source = args["source"] as? String,
          let fps = args["frameRate"] as? Int else {
      result(FlutterError(
        code: "INVALID_ARGUMENTS",
        message: "Missing required parameters: source, frameRate",
        details: nil
      ))
      return
    }

    let sourceId = args["sourceId"] as? String
    let captureAudio = args["captureAudio"] as? Bool ?? false

    Task {
      do {
        // Create capture manager if not exists
        if captureManager == nil {
          captureManager = ScreenCaptureManager()
        }

        let isWindow = source == "window"

        // If sourceId is nil and we're capturing a screen, get the main display
        var actualSourceId = sourceId
        if actualSourceId == nil && !isWindow {
          // Get main display ID
          actualSourceId = String(CGMainDisplayID())
        }

        guard let finalSourceId = actualSourceId else {
          result(FlutterError(
            code: "INVALID_ARGUMENTS",
            message: "sourceId is required for window capture",
            details: nil
          ))
          return
        }

        // Set up frame callback
        captureManager?.onFrameReceived = { [weak self] sampleBuffer in
          self?.frameStreamHandler?.sendFrame(sampleBuffer)
        }

        // Start capture
        try await captureManager?.startCapture(sourceId: finalSourceId, fps: fps, isWindow: isWindow)

        // Start audio capture if requested
        if captureAudio {
          if audioCaptureManager == nil {
            audioCaptureManager = AudioCaptureManager()
          }

          // Set up error callback
          audioCaptureManager?.onError = { error in
            print("[Plugin] Audio capture error: \(error)")
          }

          // Set up audio callback with error handling
          audioCaptureManager?.onAudioReceived = { [weak self] data, timestamp in
            guard let self = self else { return }
            guard let audioHandler = self.audioStreamHandler else {
              print("[Plugin] Warning: Audio data but no stream handler")
              return
            }
            guard let audioManager = self.audioCaptureManager else { return }
            audioHandler.sendAudio(
              data: data,
              timestamp: timestamp,
              sampleRate: Int(audioManager.sampleRate),
              channels: audioManager.channelCount
            )
          }

          // Start microphone capture
          try audioCaptureManager?.startCapture(includeMicrophone: true, includeSystem: false)
        }

        // Start cursor tracking if enabled
        let captureCursor = args["captureCursor"] as? Bool ?? true

        if captureCursor {
          if cursorTracker == nil {
            cursorTracker = CursorTracker()
          }

          // Set up cursor callback
          cursorTracker?.onCursorUpdate = { [weak self] x, y, timestamp, isClicked in
            guard let self = self else { return }
            guard let handler = self.cursorStreamHandler else {
              print("[Plugin] Warning: Cursor data but no stream handler")
              return
            }

            handler.sendCursorPosition(x: x, y: y, timestamp: timestamp, isClicked: isClicked)
          }

          cursorTracker?.onError = { error in
            print("[Plugin] Cursor tracking error: \(error)")
          }

          // Start tracking at 60 Hz
          try cursorTracker?.startTracking(frequency: 60)
        }

        result(true)
      } catch {
        result(FlutterError(
          code: "CAPTURE_FAILED",
          message: "Failed to start recording: \(error.localizedDescription)",
          details: nil
        ))
      }
    }
  }

  private func pauseRecording(result: @escaping FlutterResult) {
    // TODO: Implement later
    result(FlutterError(
      code: "NOT_IMPLEMENTED",
      message: "pauseRecording not yet implemented",
      details: nil
    ))
  }

  private func resumeRecording(result: @escaping FlutterResult) {
    // TODO: Implement later
    result(FlutterError(
      code: "NOT_IMPLEMENTED",
      message: "resumeRecording not yet implemented",
      details: nil
    ))
  }

  private func stopRecording(result: @escaping FlutterResult) {
    Task {
      do {
        guard let manager = captureManager else {
          result(FlutterError(
            code: "NOT_RECORDING",
            message: "No active recording session",
            details: nil
          ))
          return
        }

        try await manager.stopCapture()
        captureManager = nil

        // Stop audio capture if active
        if let audioManager = audioCaptureManager, audioManager.isCaptureActive() {
          // Clear callbacks first
          audioManager.onAudioReceived = nil
          audioManager.onError = nil

          // Then stop
          audioManager.stopCapture()
          audioCaptureManager = nil
        }

        // Stop cursor tracking if active
        if let tracker = cursorTracker {
          tracker.onCursorUpdate = nil
          tracker.onError = nil

          if tracker.isCurrentlyTracking() {
            tracker.stopTracking()
          }

          cursorTracker = nil
        }

        // Return empty string - video encoding happens on Flutter side
        result("")
      } catch {
        result(FlutterError(
          code: "STOP_FAILED",
          message: "Failed to stop recording: \(error.localizedDescription)",
          details: nil
        ))
      }
    }
  }

  // MARK: - Permissions

  private func requestPermissions(result: @escaping FlutterResult) {
    Task {
      do {
        let manager = ScreenCaptureManager()
        let granted = try await manager.requestPermission()
        result(granted)
      } catch {
        result(FlutterError(
          code: "PERMISSION_ERROR",
          message: "Failed to request permissions: \(error.localizedDescription)",
          details: nil
        ))
      }
    }
  }

  private func checkPermissions(result: @escaping FlutterResult) {
    Task {
      let manager = ScreenCaptureManager()
      let granted = await manager.checkPermission()
      result(granted)
    }
  }

  // MARK: - Live Recording (Phase 9)

  private func startLiveRecording(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let source = args["source"] as? String,
          let fps = args["frameRate"] as? Int,
          let outputPath = args["outputPath"] as? String,
          let width = args["width"] as? Int,
          let height = args["height"] as? Int else {
      result(FlutterError(code: "INVALID_ARGUMENTS",
                          message: "Missing required parameters",
                          details: nil))
      return
    }
    let sourceId = args["sourceId"] as? String
    let captureAudio = args["captureAudio"] as? Bool ?? false
    let captureCursor = args["captureCursor"] as? Bool ?? true

    Task {
      do {
        let writer = LiveRecordingWriter(
          outputPath: outputPath, width: width, height: height,
          fps: fps, captureAudio: captureAudio)
        try writer.start()

        let encoder = VideoToolboxEncoder(width: width, height: height, fps: fps)
        encoder.onCompressedSample = { [weak writer] sb in
          writer?.appendVideo(sb)
        }
        try encoder.initialize()

        if captureManager == nil { captureManager = ScreenCaptureManager() }
        captureManager?.onFrameReceived = { [weak encoder] sampleBuffer in
          guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            NSLog("[Phase9-cap] onFrameReceived: no image buffer")
            return
          }
          let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          do {
            try encoder?.encode(pixelBuffer: pb, timestamp: pts)
          } catch {
            NSLog("[Phase9-cap] encoder.encode threw: \(error)")
          }
        }

        let isWindow = source == "window"
        var actualSourceId = sourceId
        if actualSourceId == nil && !isWindow {
          actualSourceId = String(CGMainDisplayID())
        }
        guard let finalSourceId = actualSourceId else {
          result(FlutterError(code: "INVALID_ARGUMENTS",
                              message: "sourceId required for window capture",
                              details: nil))
          return
        }
        try await captureManager?.startCapture(sourceId: finalSourceId, fps: fps, isWindow: isWindow)

        if captureAudio {
          if audioCaptureManager == nil { audioCaptureManager = AudioCaptureManager() }
          audioCaptureManager?.onSampleBufferReceived = { [weak writer] sb in
            writer?.appendAudio(sb)
          }
          try audioCaptureManager?.startCapture(includeMicrophone: true, includeSystem: false)
        }

        if captureCursor {
          if cursorTracker == nil { cursorTracker = CursorTracker() }
          cursorTracker?.onCursorUpdate = { [weak self] x, y, ts, isClicked in
            self?.cursorStreamHandler?.sendCursorPosition(x: x, y: y, timestamp: ts, isClicked: isClicked)
          }
          try cursorTracker?.startTracking(frequency: 60)
        }

        let sampler = PerfSampler()
        sampler.start()

        self.liveWriter = writer
        self.liveEncoder = encoder
        self.perfSampler = sampler
        self.liveStartTime = Date()
        self.liveFrameCount = 0

        result(true)
      } catch {
        result(FlutterError(code: "LIVE_START_FAILED",
                            message: "Failed to start live recording: \(error.localizedDescription)",
                            details: nil))
      }
    }
  }

  private func stopLiveRecording(result: @escaping FlutterResult) {
    Task {
      do {
        NSLog("[Phase9-stop] entered stopLiveRecording")
        try await captureManager?.stopCapture()
        NSLog("[Phase9-stop] captureManager.stopCapture done")
        captureManager = nil

        if let am = audioCaptureManager, am.isCaptureActive() {
          am.onSampleBufferReceived = nil
          am.onAudioReceived = nil
          am.onError = nil
          am.stopCapture()
          audioCaptureManager = nil
        }
        NSLog("[Phase9-stop] audioCaptureManager stopped")

        if let ct = cursorTracker {
          ct.onCursorUpdate = nil
          if ct.isCurrentlyTracking() { ct.stopTracking() }
          cursorTracker = nil
        }
        NSLog("[Phase9-stop] cursorTracker stopped")

        liveEncoder?.finalize()
        NSLog("[Phase9-stop] liveEncoder.finalize done")
        let droppedFrames = liveEncoder?.droppedFrameCount ?? 0
        let encodeCalls = liveEncoder?.encodeCallCount ?? 0
        let encodeSuccess = liveEncoder?.encodeSuccessCount ?? 0
        let outputCalls = liveEncoder?.outputCallbackCount ?? 0
        NSLog("[Phase9-counts] encoder: encode_called=\(encodeCalls) encode_success=\(encodeSuccess) output_callback=\(outputCalls) dropped=\(droppedFrames)")
        liveEncoder = nil

        let stats = perfSampler?.stop()
        NSLog("[Phase9-stop] perfSampler.stop done")
        perfSampler = nil

        guard let writer = liveWriter else {
          result(FlutterError(code: "NOT_RECORDING", message: "no live writer", details: nil))
          return
        }
        liveWriter = nil

        let writerAppendCalls = writer.appendVideoCallCount
        let writerAppendAccepted = writer.appendVideoAcceptedCount
        let writerAppendNotReady = writer.appendVideoNotReadyCount
        NSLog("[Phase9-counts] writer: appendVideo_called=\(writerAppendCalls) accepted=\(writerAppendAccepted) not_ready=\(writerAppendNotReady)")
        NSLog("[Phase9-stop] calling writer.stop")
        writer.stop { stopResult in
          NSLog("[Phase9-stop] writer.stop completion fired")
          switch stopResult {
          case .success(let path):
            let payload: [String: Any] = [
              "outputPath": path,
              "droppedFrames": droppedFrames,
              "cpuPctSamples": stats?.cpuPctSamples ?? [],
              "memBytesSamples": (stats?.memBytesSamples ?? []).map { Int($0) },
            ]
            result(payload)
          case .failure(let err):
            result(FlutterError(code: "LIVE_STOP_FAILED",
                                message: "Failed to finalize: \(err.localizedDescription)",
                                details: nil))
          }
        }
      } catch {
        result(FlutterError(code: "LIVE_STOP_FAILED",
                            message: "Failed to stop live recording: \(error.localizedDescription)",
                            details: nil))
      }
    }
  }
}

// MARK: - Frame Stream Handler

class FrameStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var frameCount: Int = 0

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    self.frameCount = 0
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  func sendFrame(_ sampleBuffer: CMSampleBuffer) {
    guard let eventSink = eventSink else { return }

    // Convert CMSampleBuffer to pixel data
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    // Lock the pixel buffer
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }

    // Get pixel buffer info
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)

    // Get timestamp in microseconds
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let timestampMicros = Int64(CMTimeGetSeconds(timestamp) * 1_000_000)

    // Create FlutterStandardTypedData with pixel data
    guard let address = baseAddress else { return }
    let dataLength = bytesPerRow * height
    let data = Data(bytes: address, count: dataLength)
    let flutterData = FlutterStandardTypedData(bytes: data)

    // Create frame data dictionary
    let frameData: [String: Any] = [
      "data": flutterData,
      "width": width,
      "height": height,
      "timestampMicros": timestampMicros,
      "bytesPerRow": bytesPerRow
    ]

    // Send to Flutter on main thread
    DispatchQueue.main.async {
      eventSink(frameData)
    }

    frameCount += 1
  }
}

// MARK: - Audio Stream Handler

class AudioStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var sampleCount: Int = 0
  private var isListening = false

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    self.sampleCount = 0
    self.isListening = true
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    self.isListening = false
    return nil
  }

  func sendAudio(data: Data, timestamp: Int64, sampleRate: Int, channels: Int) {
    guard isListening, let eventSink = eventSink else { return }

    // Validate audio data
    guard !data.isEmpty, sampleRate > 0, channels > 0 else {
      print("[AudioStreamHandler] Invalid audio data")
      return
    }

    // Create FlutterStandardTypedData with audio data
    let flutterData = FlutterStandardTypedData(bytes: data)

    // Create audio data dictionary
    let audioData: [String: Any] = [
      "data": flutterData,
      "sampleRate": sampleRate,
      "channels": channels,
      "timestampMicros": timestamp
    ]

    // Send to Flutter on main thread
    DispatchQueue.main.async {
      eventSink(audioData)
    }

    sampleCount += 1
  }
}

// MARK: - Cursor Stream Handler

class CursorStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var isListening = false
  private var sampleCount: Int = 0

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    self.isListening = true
    self.sampleCount = 0
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    self.isListening = false
    return nil
  }

  func sendCursorPosition(x: Double, y: Double, timestamp: Int64, isClicked: Bool) {
    guard isListening, let eventSink = eventSink else { return }

    // Validate data
    guard x.isFinite, y.isFinite, timestamp >= 0 else {
      print("[CursorStreamHandler] Invalid cursor data: x=\(x), y=\(y), timestamp=\(timestamp)")
      return
    }

    let cursorData: [String: Any] = [
      "x": x,
      "y": y,
      "timestampMicros": timestamp,
      "isClicked": isClicked
    ]

    DispatchQueue.main.async {
      eventSink(cursorData)
    }

    sampleCount += 1
  }
}
