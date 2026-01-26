import Cocoa
import FlutterMacOS
import CoreMedia
import CoreVideo

public class ScreenRecorderMacosPlugin: NSObject, FlutterPlugin {
  private var recordingChannel: FlutterMethodChannel?
  private var captureManager: ScreenCaptureManager?
  private var frameStreamHandler: FrameStreamHandler?

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

    // TODO: Event channels for audio and cursor will be set up in later phases
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
    case "pauseRecording":
      pauseRecording(result: result)
    case "resumeRecording":
      resumeRecording(result: result)
    case "stopRecording":
      stopRecording(result: result)
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

        // TODO: Return video file path in Phase 1, Batch 2, Task 6
        result(["success": true])
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
