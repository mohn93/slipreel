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
  private var liveCaptureWidth: Int = 0
  private var liveCaptureHeight: Int = 0

  /// Maps a global, AppKit-bottom-left, screen-points cursor location
  /// (i.e. NSEvent.mouseLocation) to the recorded video's pixel space
  /// (top-left origin). Set per recording from the resolved source — see
  /// `makeCursorTransform`. When `nil`, cursor coordinates are forwarded
  /// unchanged (legacy behaviour).
  private var cursorTransform: ((Double, Double) -> (Double, Double))?

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
    case "listSources":
      listSources(call: call, result: result)
    case "captureThumbnail":
      captureThumbnail(call: call, result: result)
    case "selectRegion":
      selectRegion(call: call, result: result)
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
          let outputPath = args["outputPath"] as? String else {
      result(FlutterError(code: "INVALID_ARGUMENTS",
                          message: "Missing required parameters",
                          details: nil))
      return
    }
    let sourceId = args["sourceId"] as? String
    let captureAudio = args["captureAudio"] as? Bool ?? false
    let captureCursor = args["captureCursor"] as? Bool ?? true

    // Optional region for area capture.
    var regionSelection: RegionSelection? = nil
    if let raw = args["region"] {
      guard let map = raw as? [String: Any],
            let didStr = map["displayId"] as? String,
            let displayId = CGDirectDisplayID(didStr),
            let x = map["x"] as? Int,
            let y = map["y"] as? Int,
            let w = map["width"] as? Int,
            let h = map["height"] as? Int else {
        result(FlutterError(code: "INVALID_ARGUMENTS",
                            message: "region argument must be a map with displayId/x/y/width/height",
                            details: nil))
        return
      }
      regionSelection = RegionSelection(
        displayId: displayId, x: x, y: y, widthPx: w, heightPx: h)
    }

    Task {
      do {
        let isWindow = source == "window"
        var actualSourceId = sourceId
        if actualSourceId == nil && !isWindow {
          if let region = regionSelection {
            actualSourceId = String(region.displayId)
          } else {
            actualSourceId = String(CGMainDisplayID())
          }
        }
        guard let finalSourceId = actualSourceId else {
          result(FlutterError(code: "INVALID_ARGUMENTS",
                              message: "sourceId required for window capture",
                              details: nil))
          return
        }

        // Query the actual capture dimensions so encoder + writer match what SCStream produces.
        if captureManager == nil { captureManager = ScreenCaptureManager() }
        let captureWidth: Int
        let captureHeight: Int
        if let region = regionSelection {
          captureWidth = region.widthPx
          captureHeight = region.heightPx
        } else {
          let dims = try await captureManager!.captureDimensions(sourceId: finalSourceId, isWindow: isWindow)
          captureWidth = dims.width
          captureHeight = dims.height
        }
        let writer = LiveRecordingWriter(
          outputPath: outputPath, width: captureWidth, height: captureHeight,
          fps: fps, captureAudio: captureAudio)
        try writer.start()

        let encoder = VideoToolboxEncoder(width: captureWidth, height: captureHeight, fps: fps)
        encoder.onCompressedSample = { [weak writer] sb in
          writer?.appendVideo(sb)
        }
        try encoder.initialize()

        captureManager?.onFrameReceived = { [weak encoder] sampleBuffer in
          guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
          let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          try? encoder?.encode(pixelBuffer: pb, timestamp: pts)
        }

        try await captureManager?.startCapture(
          sourceId: finalSourceId, fps: fps, isWindow: isWindow,
          region: regionSelection)

        if captureAudio {
          if audioCaptureManager == nil { audioCaptureManager = AudioCaptureManager() }
          audioCaptureManager?.onSampleBufferReceived = { [weak writer] sb in
            writer?.appendAudio(sb)
          }
          try audioCaptureManager?.startCapture(includeMicrophone: true, includeSystem: false)
        }

        if captureCursor {
          if cursorTracker == nil { cursorTracker = CursorTracker() }
          // Build the global-points → video-pixels mapping for this
          // recording so cursor data lands in the same coordinate space
          // as the captured video frames. Computed on @MainActor because
          // it touches NSScreen.screens.
          self.cursorTransform = await MainActor.run {
            self.makeCursorTransform(
              source: source,
              sourceId: finalSourceId,
              region: regionSelection)
          }
          cursorTracker?.onCursorUpdate = { [weak self] x, y, ts, isClicked in
            guard let self = self else { return }
            let (px, py) = self.cursorTransform?(x, y) ?? (x, y)
            self.cursorStreamHandler?.sendCursorPosition(
              x: px, y: py, timestamp: ts, isClicked: isClicked)
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
        self.liveCaptureWidth = captureWidth
        self.liveCaptureHeight = captureHeight

        if let region = regionSelection {
          await MainActor.run { RegionRecordingIndicator.shared.show(region: region) }
        }

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
      await MainActor.run { RegionRecordingIndicator.shared.hide() }
      do {
        try await captureManager?.stopCapture()
        captureManager = nil

        if let am = audioCaptureManager, am.isCaptureActive() {
          am.onSampleBufferReceived = nil
          am.onAudioReceived = nil
          am.onError = nil
          am.stopCapture()
          audioCaptureManager = nil
        }

        if let ct = cursorTracker {
          ct.onCursorUpdate = nil
          if ct.isCurrentlyTracking() { ct.stopTracking() }
          cursorTracker = nil
        }
        cursorTransform = nil

        liveEncoder?.finalize()
        let droppedFrames = liveEncoder?.droppedFrameCount ?? 0
        liveEncoder = nil

        let stats = perfSampler?.stop()
        perfSampler = nil

        guard let writer = liveWriter else {
          result(FlutterError(code: "NOT_RECORDING", message: "no live writer", details: nil))
          return
        }
        liveWriter = nil

        writer.stop { stopResult in
          switch stopResult {
          case .success(let path):
            let payload: [String: Any] = [
              "outputPath": path,
              "droppedFrames": droppedFrames,
              "cpuPctSamples": stats?.cpuPctSamples ?? [],
              "memBytesSamples": (stats?.memBytesSamples ?? []).map { Int($0) },
              "width": self.liveCaptureWidth,
              "height": self.liveCaptureHeight,
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

  // MARK: - Source picker

  /// Build a closure that maps NSEvent.mouseLocation (global, AppKit
  /// bottom-left origin, screen points) into the recorded video's pixel
  /// space (top-left origin within the captured rect). Returns `nil` for
  /// sources we can't introspect synchronously (e.g. window capture —
  /// SCWindow lookup is async); cursor data for those falls through
  /// untransformed.
  @MainActor
  private func makeCursorTransform(
    source: String,
    sourceId: String,
    region: RegionSelection?
  ) -> ((Double, Double) -> (Double, Double))? {
    // For area capture we know the recording is `region` pixels inside
    // the display identified by region.displayId.
    if source == "area", let r = region {
      guard let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? CGDirectDisplayID) == r.displayId
      }) else { return nil }
      let scale = Double(screen.backingScaleFactor)
      let displayMinX = Double(screen.frame.minX)
      let displayMaxY = Double(screen.frame.maxY)
      let regionLocalXPoints = Double(r.x) / scale
      let regionLocalYPoints = Double(r.y) / scale
      return { gx, gy in
        // Cursor in display-local top-left points.
        let xInDisplayPts = gx - displayMinX
        let yInDisplayPts = displayMaxY - gy
        // Cursor in region-local top-left points, then scaled to pixels.
        let xPx = (xInDisplayPts - regionLocalXPoints) * scale
        let yPx = (yInDisplayPts - regionLocalYPoints) * scale
        return (xPx, yPx)
      }
    }

    // For full-display capture the recording covers the entire display
    // identified by sourceId.
    if source == "screen", let displayId = CGDirectDisplayID(sourceId),
       let screen = NSScreen.screens.first(where: {
         ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
           as? CGDirectDisplayID) == displayId
       }) {
      let scale = Double(screen.backingScaleFactor)
      let displayMinX = Double(screen.frame.minX)
      let displayMaxY = Double(screen.frame.maxY)
      return { gx, gy in
        let xInDisplayPts = gx - displayMinX
        let yInDisplayPts = displayMaxY - gy
        return (xInDisplayPts * scale, yInDisplayPts * scale)
      }
    }

    // Window capture: SCWindow.frame is async to fetch and the window
    // can move during recording. Skip for v1; cursor data is left in
    // global-points form and the editor will fall back to rect.center
    // for that source type.
    return nil
  }

  private func selectRegion(call: FlutterMethodCall, result: @escaping FlutterResult) {
    Task { @MainActor in
      let selection = await RegionSelector.shared.selectRegion()
      if let s = selection {
        result([
          "displayId": String(s.displayId),
          "x": s.x,
          "y": s.y,
          "width": s.widthPx,
          "height": s.heightPx,
        ])
      } else {
        result(nil)
      }
    }
  }

  private func listSources(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.arguments == nil || call.arguments is [String: Any] else {
      result(FlutterError(code: "INVALID_ARGUMENTS",
                          message: "listSources argument must be a map",
                          details: nil))
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    let strict = args["strictFilter"] as? Bool ?? true
    Task {
      do {
        let lists = try await SourceCatalog.listSources(strictFilter: strict)
        result(["windows": lists.windows, "screens": lists.screens])
      } catch {
        result(FlutterError(code: "DISCOVERY_FAILED",
                            message: "listSources failed: \(error.localizedDescription)",
                            details: nil))
      }
    }
  }

  private func captureThumbnail(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let id = args["id"] as? String,
          let kindRaw = args["kind"] as? String,
          let kind = ThumbnailKind(rawValue: kindRaw),
          let maxDim = args["maxDimension"] as? Int else {
      result(FlutterError(code: "INVALID_ARGUMENTS",
                          message: "captureThumbnail requires { id, kind, maxDimension }",
                          details: nil))
      return
    }
    guard maxDim > 0, maxDim <= 2048 else {
      result(FlutterError(code: "INVALID_ARGUMENTS",
                          message: "maxDimension must be between 1 and 2048",
                          details: nil))
      return
    }
    Task {
      do {
        let data = try await ThumbnailCapture.capture(sourceId: id, kind: kind, maxDimension: maxDim)
        result(FlutterStandardTypedData(bytes: data))
      } catch {
        result(nil)
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
