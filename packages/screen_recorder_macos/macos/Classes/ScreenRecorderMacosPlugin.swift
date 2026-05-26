import ApplicationServices
import AVFoundation
import Cocoa
import FlutterMacOS
import CoreMedia
import CoreVideo
import ScreenCaptureKit

public class ScreenRecorderMacosPlugin: NSObject, FlutterPlugin {
  private var recordingChannel: FlutterMethodChannel?
  private var captureManager: ScreenCaptureManager?
  private var audioCaptureManager: AudioCaptureManager?
  private var systemAudioManager: Any?  // SystemAudioCaptureManager (gated to macOS 13+)
  private var frameStreamHandler: FrameStreamHandler?
  private var audioStreamHandler: AudioStreamHandler?
  private var cursorStreamHandler: CursorStreamHandler?
  private var cursorTracker: CursorTracker?
  private var micLevelStreamHandler: MicLevelStreamHandler?
  private let micLevelMonitor = MicLevelMonitor()

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

  /// Wall-clock time the FIRST video frame arrived at the encoder for
  /// the active recording. Cursor sample timestamps are rebased against
  /// this so they align with VideoPlayerController.value.position during
  /// playback. SCStream takes ~tens to hundreds of ms to spin up between
  /// startCapture() returning and the first frame actually appearing —
  /// using liveStartTime instead would shift cursor data ahead of the
  /// video by exactly that delay.
  private var firstVideoFrameAt: Date?

  public static func register(with registrar: FlutterPluginRegistrar) {
    // Main method channel for recording control
    let recordingChannel = FlutterMethodChannel(
      name: "com.slipreel.screen_recorder/recording",
      binaryMessenger: registrar.messenger
    )

    let instance = ScreenRecorderMacosPlugin()
    instance.recordingChannel = recordingChannel
    registrar.addMethodCallDelegate(instance, channel: recordingChannel)

    // Event channel for video frames
    let framesChannel = FlutterEventChannel(
      name: "com.slipreel.screen_recorder/frames",
      binaryMessenger: registrar.messenger
    )
    instance.frameStreamHandler = FrameStreamHandler()
    framesChannel.setStreamHandler(instance.frameStreamHandler)

    // Event channel for audio samples
    let audioChannel = FlutterEventChannel(
      name: "com.slipreel.screen_recorder/audio",
      binaryMessenger: registrar.messenger
    )
    instance.audioStreamHandler = AudioStreamHandler()
    audioChannel.setStreamHandler(instance.audioStreamHandler)

    // Event channel for cursor tracking
    let cursorChannel = FlutterEventChannel(
      name: "com.slipreel.screen_recorder/cursor",
      binaryMessenger: registrar.messenger
    )
    instance.cursorStreamHandler = CursorStreamHandler()
    cursorChannel.setStreamHandler(instance.cursorStreamHandler)

    let micLevelChannel = FlutterEventChannel(
      name: "com.slipreel.screen_recorder/micLevel",
      binaryMessenger: registrar.messenger
    )
    instance.micLevelStreamHandler = MicLevelStreamHandler()
    micLevelChannel.setStreamHandler(instance.micLevelStreamHandler)
    instance.micLevelMonitor.onLevel = { [weak instance] level in
      instance?.micLevelStreamHandler?.send(level)
    }

    // Register the app with macOS's Accessibility TCC list at plugin
    // load. Without this an app that has never asked for the permission
    // doesn't appear in System Settings → Privacy & Security →
    // Accessibility — the user opens the pane, doesn't see us, and
    // concludes the permission can't be granted at all.
    //
    // We do BOTH things that empirically register an app with TCC:
    //   1. `AXIsProcessTrustedWithOptions` with prompt=false. On most
    //      macOS versions this alone is enough.
    //   2. Actually attempt an AX API call (`AXUIElementCopyAttributeValue`
    //      on the system-wide element). On stricter macOS versions
    //      TCC only registers an app once it sees a real AX request.
    //      The call returns kAXErrorAPIDisabled when untrusted; we
    //      ignore the result, the side-effect (registration) is what
    //      we're after.
    //
    // The banner's "Open Accessibility settings" button uses the same
    // API with prompt=true to pop the modal when the user opts in.
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
    let trusted = AXIsProcessTrustedWithOptions(
      [promptKey: false] as CFDictionary)
    var role: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(
      AXUIElementCreateSystemWide(),
      kAXRoleAttribute as CFString,
      &role)
    print(
      "[ScreenRecorderMacosPlugin] Accessibility registered. "
        + "trusted=\(trusted). If this is the first launch on this build, "
        + "the app should now appear in System Settings → Privacy & Security "
        + "→ Accessibility (relaunch required after granting).")
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
    case "pickSource":
      pickSource(call: call, result: result)
    case "getAudioDevices":
      getAudioDevices(result: result)
    case "showMicrophoneMenu":
      showMicrophoneMenu(args: call.arguments as? [String: Any], result: result)
    case "showSystemAudioMenu":
      showSystemAudioMenu(args: call.arguments as? [String: Any], result: result)
    case "startMicMonitor":
      if let args = call.arguments as? [String: Any] {
        micLevelMonitor.start(
          deviceUid: args["deviceUid"] as? String,
          reduceNoise: args["reduceNoise"] as? Bool ?? false,
          disableAgc: args["disableAgc"] as? Bool ?? false)
      }
      result(nil)
    case "stopMicMonitor":
      micLevelMonitor.stop()
      result(nil)
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
    case "getStockCursorImages":
      getStockCursorImages(result: result)
    case "isAccessibilityTrusted":
      result(AXIsProcessTrusted())
    case "requestAccessibilityPermission":
      // Pass `kAXTrustedCheckOptionPrompt = true` so macOS shows the
      // "X would like to control this computer using accessibility
      // features" dialog. The user has to flip the toggle in System
      // Settings; macOS only updates the trust state after a relaunch
      // of the host process.
      let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
      let options = [promptKey: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
      result(nil)
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
    result(AudioDeviceCatalog.inputDevices())
  }

  private func showMicrophoneMenu(args: [String: Any]?, result: @escaping FlutterResult) {
    let current = args // {deviceUid, deviceLabel, reduceNoise, disableAgc} or nil
    let curUid = current?["deviceUid"] as? String
    let curReduceNoise = current?["reduceNoise"] as? Bool ?? false
    let curDisableAgc = current?["disableAgc"] as? Bool ?? false

    DispatchQueue.main.async {
      let target = MicMenuTarget()
      let menu = NSMenu()
      let status = AVCaptureDevice.authorizationStatus(for: .audio)

      if status == .denied || status == .restricted {
        let info = NSMenuItem(
          title: "Microphone access denied — enable in System Settings ▸ Privacy",
          action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
      }

      for dev in AudioDeviceCatalog.inputDevices() {
        let uid = dev["id"] as? String ?? ""
        let name = dev["name"] as? String ?? uid
        let isDefault = dev["isDefault"] as? Bool ?? false
        let item = NSMenuItem(
          title: isDefault ? "\(name) (default)" : name,
          action: #selector(MicMenuTarget.pickDevice(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = ["uid": uid, "label": name]
        item.state = (uid == curUid) ? .on : .off
        menu.addItem(item)
      }

      menu.addItem(.separator())

      let noise = NSMenuItem(title: "Reduce noise and normalize volume",
        action: #selector(MicMenuTarget.toggleReduceNoise(_:)), keyEquivalent: "")
      noise.target = target
      noise.state = curReduceNoise ? .on : .off
      noise.isEnabled = (curUid != nil) // only meaningful with a device selected
      menu.addItem(noise)

      if #available(macOS 14.0, *) {
        let agc = NSMenuItem(title: "Disable auto gain control",
          action: #selector(MicMenuTarget.toggleDisableAgc(_:)), keyEquivalent: "")
        agc.target = target
        agc.state = curDisableAgc ? .on : .off
        agc.isEnabled = (curUid != nil && curReduceNoise)
        menu.addItem(agc)
      }

      menu.addItem(.separator())
      let off = NSMenuItem(title: "Don't record microphone",
        action: #selector(MicMenuTarget.dontRecord(_:)), keyEquivalent: "")
      off.target = target
      off.state = (curUid == nil) ? .on : .off
      menu.addItem(off)

      menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)

      // Compute the new config from the click.
      func reply(_ config: [String: Any]?) {
        result(["cancelled": false, "config": (config as Any?) ?? NSNull()])
      }
      func configMap(uid: String, label: String, reduceNoise: Bool, disableAgc: Bool) -> [String: Any] {
        ["deviceUid": uid, "deviceLabel": label, "reduceNoise": reduceNoise, "disableAgc": disableAgc]
      }

      switch target.action {
      case .none:
        result(["cancelled": true, "config": NSNull()])
      case .dontRecord:
        reply(nil)
      case .toggleReduceNoise:
        guard let uid = curUid, let label = current?["deviceLabel"] as? String else { reply(nil); return }
        reply(configMap(uid: uid, label: label, reduceNoise: !curReduceNoise, disableAgc: curDisableAgc))
      case .device(let uid, let label):
        // Newly selecting a device: ensure permission first.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
          AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
              if granted {
                reply(configMap(uid: uid, label: label, reduceNoise: curReduceNoise, disableAgc: curDisableAgc))
              } else {
                reply(nil)
              }
            }
          }
        } else if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
          reply(configMap(uid: uid, label: label, reduceNoise: curReduceNoise, disableAgc: curDisableAgc))
        } else {
          reply(nil) // denied/restricted
        }
      case .toggleDisableAgc:
        guard let uid = curUid, let label = current?["deviceLabel"] as? String else { reply(nil); return }
        reply(configMap(uid: uid, label: label, reduceNoise: curReduceNoise, disableAgc: !curDisableAgc))
      }
    }
  }

  private func showSystemAudioMenu(args: [String: Any]?, result: @escaping FlutterResult) {
    let curMode = args?["mode"] as? String          // "allApps" | "selectedApps" | nil(off)
    let curBundleIds = Set((args?["bundleIds"] as? [String]) ?? [])

    guard #available(macOS 13.0, *) else {
      result(["cancelled": false, "config": NSNull()]); return
    }

    Task { @MainActor in
      // Enumerate running apps so each becomes an inline checkbox row.
      let content = try? await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)
      var seen = Set<String>()
      let apps = (content?.applications ?? [])
        .filter { !$0.bundleIdentifier.isEmpty && !$0.applicationName.isEmpty
                  && seen.insert($0.bundleIdentifier).inserted }
        .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName)
                  == .orderedAscending }

      let target = SysAudioMenuTarget()
      let menu = NSMenu()

      let all = NSMenuItem(title: "Record system audio from all apps",
        action: #selector(SysAudioMenuTarget.pickAll(_:)), keyEquivalent: "")
      all.target = target
      all.state = (curMode == "allApps") ? .on : .off
      menu.addItem(all)

      menu.addItem(.separator())
      let header = NSMenuItem(title: "Selected apps", action: nil, keyEquivalent: "")
      header.isEnabled = false
      menu.addItem(header)

      // Each app is a custom-view checkbox row: clicking a checkbox inside a
      // menu item's view does NOT dismiss the menu, so several apps can be
      // toggled in one pass. We read the checkbox states after the menu closes.
      var checkboxes: [(bundleId: String, button: NSButton)] = []
      if apps.isEmpty {
        let none = NSMenuItem(title: "  (no apps available)", action: nil, keyEquivalent: "")
        none.isEnabled = false
        menu.addItem(none)
      }
      for app in apps {
        let button = NSButton(checkboxWithTitle: app.applicationName,
                              target: nil, action: nil)
        button.state = curBundleIds.contains(app.bundleIdentifier) ? .on : .off
        button.sizeToFit()
        let rowH = max(22, button.frame.height + 4)
        let rowW = max(240, button.frame.width + 44)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: rowW, height: rowH))
        button.setFrameOrigin(NSPoint(x: 20, y: (rowH - button.frame.height) / 2))
        view.addSubview(button)
        let item = NSMenuItem()
        item.view = view
        menu.addItem(item)
        checkboxes.append((app.bundleIdentifier, button))
      }

      menu.addItem(.separator())
      let off = NSMenuItem(title: "Don't record system audio",
        action: #selector(SysAudioMenuTarget.dontRecord(_:)), keyEquivalent: "")
      off.target = target
      off.state = (curMode == nil) ? .on : .off
      menu.addItem(off)

      menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)

      func reply(_ config: [String: Any]?) {
        result(["cancelled": false, "config": (config as Any?) ?? NSNull()])
      }

      switch target.action {
      case .all:
        reply(["mode": "allApps", "bundleIds": [String]()])
      case .dontRecord:
        reply(nil)
      case .none:
        // Dismissed by clicking away / Escape — apply whatever apps are checked.
        let chosen = checkboxes.filter { $0.button.state == .on }.map { $0.bundleId }
        if chosen.isEmpty {
          result(["cancelled": true, "config": NSNull()]) // no change
        } else {
          reply(["mode": "selectedApps", "bundleIds": chosen])
        }
      }
    }
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
          cursorTracker?.onCursorUpdate = { [weak self] x, y, timestamp, isClicked, state in
            guard let self = self else { return }
            guard let handler = self.cursorStreamHandler else {
              print("[Plugin] Warning: Cursor data but no stream handler")
              return
            }

            handler.sendCursorPosition(
              x: x, y: y, timestamp: timestamp, isClicked: isClicked, state: state
            )
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
    micLevelMonitor.stop()
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
    let micArgs = args["microphone"] as? [String: Any]   // nil → don't record mic
    let captureMic = micArgs != nil
    let sysArgs = args["systemAudio"] as? [String: Any]   // nil → don't record system audio
    let captureSystem = sysArgs != nil
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
        // Defensive teardown of any leftover subsystems from a
        // previous failed start. Without this, audio capture (or
        // cursor tracker / screen capture) left half-running by an
        // earlier crash would block this attempt with "already
        // capturing". canStartRecording on the Flutter side already
        // prevents legitimate double-Records — so anything alive here
        // is stale state we want gone.
        await self.tearDownPartialLiveRecording()

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
          fps: fps, audioTracks: {
            var roles: [AudioTrackRole] = []
            if captureMic { roles.append(.microphone) }
            if captureSystem { roles.append(.system) }
            return roles
          }())
        try writer.start()

        let encoder = VideoToolboxEncoder(width: captureWidth, height: captureHeight, fps: fps)
        encoder.onCompressedSample = { [weak writer] sb in
          writer?.appendVideo(sb)
        }
        try encoder.initialize()

        captureManager?.onFrameReceived = { [weak self, weak encoder] sampleBuffer in
          guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
          let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          if let self = self, self.firstVideoFrameAt == nil {
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            self.firstVideoFrameAt = FirstFrameTiming.captureInstant(
              nowWall: Date(),
              hostNowSeconds: CMTimeGetSeconds(hostNow),
              ptsSeconds: CMTimeGetSeconds(pts))
          }
          try? encoder?.encode(pixelBuffer: pb, timestamp: pts)
        }

        try await captureManager?.startCapture(
          sourceId: finalSourceId, fps: fps, isWindow: isWindow,
          region: regionSelection)

        if let mic = micArgs {
          let uid = mic["deviceUid"] as? String
          let reduceNoise = mic["reduceNoise"] as? Bool ?? false
          let disableAgc = mic["disableAgc"] as? Bool ?? false
          if audioCaptureManager == nil { audioCaptureManager = AudioCaptureManager() }
          audioCaptureManager?.onSampleBufferReceived = { [weak writer] sb in
            writer?.appendAudio(sb, role: .microphone)
          }
          try audioCaptureManager?.startMicrophoneCapture(
            deviceUid: uid, reduceNoise: reduceNoise, disableAgc: disableAgc)
        }

        if let sys = sysArgs, #available(macOS 13.0, *) {
          let modeStr = sys["mode"] as? String ?? "allApps"
          let mode = SystemAudioMode(rawValue: modeStr) ?? .allApps
          let bundleIds = (sys["bundleIds"] as? [String]) ?? []
          let manager = SystemAudioCaptureManager()
          manager.onSampleBufferReceived = { [weak writer] sb in
            writer?.appendAudio(sb, role: .system)
          }
          do {
            try await manager.start(mode: mode, bundleIds: bundleIds)
            self.systemAudioManager = manager
          } catch {
            // Degrade gracefully: drop the system track, keep recording.
            NSLog("System audio capture failed to start: \(error)")
          }
        }

        // liveStartTime must be set BEFORE cursor tracking begins so the
        // cursor callback can rebase timestamps to video-relative time.
        // Without this, cursor samples would carry mach_absolute_time
        // values while playback queries are 0-based video time, and
        // every lookup would clamp to the first sample.
        self.liveStartTime = Date()

        if captureCursor {
          if cursorTracker == nil { cursorTracker = CursorTracker() }
          // Build the global-points → video-pixels mapping for this
          // recording so cursor data lands in the same coordinate space
          // as the captured video frames. Computed on @MainActor because
          // it touches NSScreen.screens.
          //
          // Snapshot `regionSelection` (a `var` higher in this scope)
          // into a `let` before crossing into the MainActor closure —
          // capturing a `var` in concurrent code is an error under the
          // Swift 6 language mode.
          let regionForTransform = regionSelection
          self.cursorTransform = await MainActor.run {
            self.makeCursorTransform(
              source: source,
              sourceId: finalSourceId,
              region: regionForTransform,
              videoWidthPx: captureWidth,
              videoHeightPx: captureHeight)
          }
          cursorTracker?.onCursorUpdate = { [weak self] x, y, _, isClicked, state in
            guard let self = self else { return }
            guard let frameStart = self.firstVideoFrameAt else { return }
            guard let videoMicros = FirstFrameTiming.videoMicros(
              now: Date(), since: frameStart) else { return }
            let (px, py) = self.cursorTransform?(x, y) ?? (x, y)
            self.cursorStreamHandler?.sendCursorPosition(
              x: px, y: py, timestamp: videoMicros, isClicked: isClicked, state: state)
          }
          try cursorTracker?.startTracking(frequency: 60)
        }

        let sampler = PerfSampler()
        sampler.start()

        self.liveWriter = writer
        self.liveEncoder = encoder
        self.perfSampler = sampler
        self.liveFrameCount = 0
        self.liveCaptureWidth = captureWidth
        self.liveCaptureHeight = captureHeight

        if let region = regionSelection {
          await MainActor.run { RegionRecordingIndicator.shared.show(region: region) }
        }

        result(true)
      } catch {
        // Roll back any subsystems that already started. Without this,
        // a partial failure leaves audio capture / cursor tracking /
        // screen capture running, and the *next* Record click bails
        // immediately with "already capturing" from whichever one
        // got the furthest. Each helper guards its own state so this
        // is safe to call regardless of how far the startup got.
        await self.tearDownPartialLiveRecording()
        result(FlutterError(code: "LIVE_START_FAILED",
                            message: "Failed to start live recording: \(error.localizedDescription)",
                            details: nil))
      }
    }
  }

  /// Best-effort teardown of every live-recording subsystem. Called
  /// from the start-path catch to clean up after a partial failure,
  /// so the next Record click sees a clean slate.
  ///
  /// Mirrors the structure of `stopLiveRecording`'s success path but
  /// every step is wrapped in optional / state guards: it's normal
  /// for some of these subsystems to be nil here (the failure may
  /// have happened before they were created).
  private func tearDownPartialLiveRecording() async {
    print("[tearDown] entering — "
      + "captureManager=\(captureManager != nil) "
      + "audioMgr=\(audioCaptureManager != nil)(active=\(audioCaptureManager?.isCaptureActive() ?? false)) "
      + "cursorTracker=\(cursorTracker != nil)(tracking=\(cursorTracker?.isCurrentlyTracking() ?? false)) "
      + "writer=\(liveWriter != nil) encoder=\(liveEncoder != nil)")
    if let cm = captureManager {
      try? await cm.stopCapture()
      captureManager = nil
    }
    if let am = audioCaptureManager {
      // Stop unconditionally — even if isCaptureActive() reports
      // false, leftover AVAudioEngine state from a half-aborted start
      // can still trip the next attempt's `alreadyCapturing` guard.
      am.onSampleBufferReceived = nil
      am.onAudioReceived = nil
      am.onError = nil
      am.stopCapture()
      audioCaptureManager = nil
    }
    if #available(macOS 13.0, *),
       let sysMgr = self.systemAudioManager as? SystemAudioCaptureManager {
      sysMgr.stop()
    }
    self.systemAudioManager = nil
    if let ct = cursorTracker {
      ct.onCursorUpdate = nil
      if ct.isCurrentlyTracking() { ct.stopTracking() }
      cursorTracker = nil
    }
    cursorTransform = nil
    firstVideoFrameAt = nil
    if let enc = liveEncoder {
      enc.finalize()
      liveEncoder = nil
    }
    if let writer = liveWriter {
      writer.stop { _ in /* discard partial file */ }
      liveWriter = nil
    }
    perfSampler = nil
    liveStartTime = nil
    await MainActor.run { RegionRecordingIndicator.shared.hide() }
    print("[tearDown] done")
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

        if #available(macOS 13.0, *),
           let sysMgr = self.systemAudioManager as? SystemAudioCaptureManager {
          sysMgr.stop()
        }
        self.systemAudioManager = nil

        if let ct = cursorTracker {
          ct.onCursorUpdate = nil
          if ct.isCurrentlyTracking() { ct.stopTracking() }
          cursorTracker = nil
        }
        cursorTransform = nil
        firstVideoFrameAt = nil

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
    region: RegionSelection?,
    videoWidthPx: Int,
    videoHeightPx: Int
  ) -> ((Double, Double) -> (Double, Double))? {
    // The "effective scale" — pixels of recorded video per display point
    // — is NOT always equal to NSScreen.backingScaleFactor. On Apple
    // Silicon the system can capture at logical-point resolution while
    // the screen still reports backingScaleFactor 2.0. Always derive
    // the scale from the actual video dimensions vs the display's point
    // dimensions so the math matches what SCStream produced.

    // For area capture we know the recording is `region` pixels inside
    // the display identified by region.displayId.
    if source == "area", let r = region {
      guard let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? CGDirectDisplayID) == r.displayId
      }) else {
        print("[CursorTransform] area branch BAILED — "
          + "no NSScreen matches displayId=\(r.displayId). "
          + "Cursor will be in raw global coords.")
        return nil
      }
      let displayMinX = Double(screen.frame.minX)
      let displayMaxY = Double(screen.frame.maxY)
      let scale = Double(screen.backingScaleFactor)
      let regionXPx = Double(r.x)
      let regionYPx = Double(r.y)
      print("[CursorTransform] area branch INITIALISED — "
        + "displayId=\(r.displayId) "
        + "displayMinX=\(displayMinX) displayMaxY=\(displayMaxY) "
        + "regionPx=(\(regionXPx), \(regionYPx), \(r.widthPx)×\(r.heightPx)) "
        + "scale=\(scale)")
      let sampleCounter = SampleCounter()
      return { gx, gy in
        let mapped = CursorCoordinateMapper.mapForArea(
          cursorGlobalX: gx,
          cursorGlobalY: gy,
          displayMinX: displayMinX,
          displayMaxY: displayMaxY,
          backingScale: scale,
          regionXPx: regionXPx,
          regionYPx: regionYPx)
        let n = sampleCounter.bump()
        if n <= 30 {
          print("[CursorTransform/area] #\(n) "
            + "global=(\(gx), \(gy)) → px=(\(mapped.x), \(mapped.y))")
        }
        return mapped
      }
    }

    // For full-display capture the recording covers the entire display
    // identified by sourceId.
    if source == "screen", let displayId = CGDirectDisplayID(sourceId),
       let screen = NSScreen.screens.first(where: {
         ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
           as? CGDirectDisplayID) == displayId
       }) {
      let displayMinX = Double(screen.frame.minX)
      let displayMaxY = Double(screen.frame.maxY)
      let displayWidthPts = Double(screen.frame.width)
      let displayHeightPts = Double(screen.frame.height)
      let widthPx = videoWidthPx
      let heightPx = videoHeightPx
      print("[CursorTransform] screen branch INITIALISED — "
        + "displayId=\(displayId) "
        + "displayMin=(\(displayMinX),?) displayMax=(?,\(displayMaxY)) "
        + "displayPts=\(displayWidthPts)×\(displayHeightPts) "
        + "videoPx=\(widthPx)×\(heightPx)")
      let sampleCounter = SampleCounter()
      return { gx, gy in
        let mapped = CursorCoordinateMapper.mapForScreen(
          cursorGlobalX: gx,
          cursorGlobalY: gy,
          displayMinX: displayMinX,
          displayMaxY: displayMaxY,
          displayWidthPts: displayWidthPts,
          displayHeightPts: displayHeightPts,
          videoWidthPx: widthPx,
          videoHeightPx: heightPx)
        let n = sampleCounter.bump()
        if n <= 30 {
          print("[CursorTransform/screen] #\(n) "
            + "global=(\(gx), \(gy)) → px=(\(mapped.x), \(mapped.y))")
        }
        return mapped
      }
    }

    // Window capture: live-track the window's origin from
    // `CGWindowListCopyWindowInfo` on every cursor sample so dragging
    // the window during recording stays correctly mapped. Pixels-per-
    // point comes from the framebuffer dimensions (locked at start)
    // divided by the window's *initial* size — SCStream's framebuffer
    // dims don't update if the user resizes the window mid-recording,
    // so the math wouldn't be meaningful for that case anyway.
    print("[CursorTransform] makeCursorTransform "
      + "source=\(source) sourceId=\(sourceId) "
      + "videoPx=\(videoWidthPx)×\(videoHeightPx)")
    if source == "window", let idRaw = UInt32(sourceId) {
      let windowID = CGWindowID(idRaw)
      guard let initialBounds = Self.fetchWindowBoundsPts(windowID: windowID),
            initialBounds.width > 0, initialBounds.height > 0
      else {
        print("[CursorTransform] window branch BAILED — "
          + "fetchWindowBoundsPts returned nil or zero size for "
          + "windowID=\(windowID). Cursor will be in raw global coords.")
        return nil
      }
      // Primary display's height in points — the anchor that converts
      // Cocoa (bottom-left of primary) to Quartz (top-left of primary).
      // CGWindowBounds is Quartz; NSEvent.mouseLocation is Cocoa.
      let primaryScreenHeightPts = Double(
        NSScreen.screens.first(where: {
          $0.frame.origin.x == 0 && $0.frame.origin.y == 0
        })?.frame.height
          ?? NSScreen.main?.frame.height
          ?? 0)
      let pixelsPerPointX =
        Double(videoWidthPx) / Double(initialBounds.width)
      let pixelsPerPointY =
        Double(videoHeightPx) / Double(initialBounds.height)
      print("[CursorTransform] window branch INITIALISED — "
        + "windowID=\(windowID) "
        + "initialBounds=\(initialBounds) "
        + "primaryHeight=\(primaryScreenHeightPts) "
        + "ppp=(\(pixelsPerPointX), \(pixelsPerPointY))")
      // Throttle per-sample logs so we don't flood the console at
      // 60 Hz — log only the first ~30 samples (≈0.5 s of recording).
      let sampleCounter = SampleCounter()
      return { gx, gy in
        // Live-fetch the window's current bounds. If the window
        // disappeared (closed mid-recording), fall back to the last
        // known origin — better than crashing, and the recording will
        // stop shortly anyway.
        let liveBounds =
          Self.fetchWindowBoundsPts(windowID: windowID) ?? initialBounds
        let mapped = CursorCoordinateMapper.mapForWindow(
          cursorGlobalX: gx,
          cursorGlobalY: gy,
          windowQuartzX: Double(liveBounds.origin.x),
          windowQuartzY: Double(liveBounds.origin.y),
          primaryScreenHeightPts: primaryScreenHeightPts,
          pixelsPerPointX: pixelsPerPointX,
          pixelsPerPointY: pixelsPerPointY)
        let n = sampleCounter.bump()
        if n <= 30 {
          print("[CursorTransform] #\(n) "
            + "global=(\(gx), \(gy)) "
            + "winQuartz=(\(liveBounds.origin.x), \(liveBounds.origin.y)) "
            + "winSize=(\(liveBounds.size.width), \(liveBounds.size.height)) "
            + "→ px=(\(mapped.x), \(mapped.y))")
        }
        return mapped
      }
    }
    print("[CursorTransform] no branch matched — "
      + "cursor will be in raw global coords")
    return nil
  }

  /// Thread-safe counter so the diagnostic log inside the cursor
  /// transform closure (called on the main thread from the cursor
  /// timer) can throttle itself to a finite number of samples.
  private final class SampleCounter {
    private var n = 0
    func bump() -> Int {
      n += 1
      return n
    }
  }

  /// Extract every stock `NSCursor` we render as a PNG + hot-spot
  /// and ship to Dart. The renderer caches these `ui.Image`s and
  /// blits them directly instead of approximating each cursor with a
  /// hand-coded polygon — pixel-identical to what macOS draws, scales
  /// cleanly via `Canvas.drawImageRect`. Called once at app start.
  ///
  /// Wire format: `{ stateName: { png: Uint8List, hotX: Double,
  /// hotY: Double, width: Int, height: Int } }`. State names match
  /// `CursorState.wireName` on the Dart side; missing entries fall
  /// back to the polygon path.
  private func getStockCursorImages(result: @escaping FlutterResult) {
    var entries: [(String, NSCursor)] = [
      ("arrow", .arrow),
      ("iBeam", .iBeam),
      ("pointingHand", .pointingHand),
      ("crosshair", .crosshair),
      ("resizeNS", .resizeUpDown),
      ("resizeEW", .resizeLeftRight),
      ("openHand", .openHand),
      ("closedHand", .closedHand),
      ("notAllowed", .operationNotAllowed),
    ]
    // Diagonal resize cursors come from private NSCursor selectors —
    // see CursorTracker.privateResizeCursor for the rationale. We
    // gate them behind responds(to:) so a future macOS that removes
    // the selectors silently falls back to the polygon glyph.
    if let nesw = CursorTracker.privateResizeCursor(
      selector: "_windowResizeNorthEastSouthWestCursor")
    {
      entries.append(("resizeNESW", nesw))
    }
    if let nwse = CursorTracker.privateResizeCursor(
      selector: "_windowResizeNorthWestSouthEastCursor")
    {
      entries.append(("resizeNWSE", nwse))
    }
    var payload: [String: [String: Any]] = [:]
    for (name, cursor) in entries {
      let image = cursor.image
      let hotSpot = cursor.hotSpot
      // NSImage carries multiple bitmap representations (1x and 2x
      // on Retina). We pick the largest pixel-dimension one so the
      // rendered cursor stays crisp when the user dials up the
      // cursor-size slider.
      let bestRep: NSImageRep? = image.representations
        .compactMap { $0 as? NSBitmapImageRep }
        .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
        ?? image.representations.first
      // Convert to PNG bytes via NSBitmapImageRep — works for both
      // bitmap reps and vector reps (rasterized at the size we ask).
      var pngData: Data?
      var pixelWidth = Int(image.size.width)
      var pixelHeight = Int(image.size.height)
      if let bitmap = bestRep as? NSBitmapImageRep {
        pngData = bitmap.representation(using: .png, properties: [:])
        pixelWidth = bitmap.pixelsWide
        pixelHeight = bitmap.pixelsHigh
      } else if let cg = image.cgImage(
        forProposedRect: nil, context: nil, hints: nil)
      {
        let bitmap = NSBitmapImageRep(cgImage: cg)
        pngData = bitmap.representation(using: .png, properties: [:])
        pixelWidth = bitmap.pixelsWide
        pixelHeight = bitmap.pixelsHigh
      }
      guard let png = pngData else { continue }
      payload[name] = [
        "png": FlutterStandardTypedData(bytes: png),
        // Hot-spot is in NSImage points; the renderer scales it
        // alongside the cursor diameter so the click point stays
        // aligned to the user's cursor position regardless of size.
        "hotX": Double(hotSpot.x),
        "hotY": Double(hotSpot.y),
        "imageWidth": Double(image.size.width),
        "imageHeight": Double(image.size.height),
        "pixelWidth": pixelWidth,
        "pixelHeight": pixelHeight,
      ]
    }
    result(payload)
  }

  /// Synchronous lookup of a window's bounds (Quartz coordinates,
  /// points). Cheap — `CGWindowListCopyWindowInfo` with a single
  /// window ID hits the WindowServer with the smallest possible query.
  /// Called on every cursor sample (60 Hz) to track windows that the
  /// user is dragging during recording.
  ///
  /// `.optionIncludingWindow` is meant to be used *alone* — combining
  /// it with `.optionOnScreenOnly` turns the meaning into
  /// "this-window OR on-screen", and `list.first` then returns some
  /// unrelated on-screen window. We still walk the list and match by
  /// `kCGWindowNumber` defensively in case the option-flag semantics
  /// shift in a future macOS.
  ///
  /// `kCGWindowBounds` values bridge to NSNumber of varying numeric
  /// kinds — sometimes Int, sometimes Double — so cast through
  /// `NSDictionary` + `CGRect(dictionaryRepresentation:)` rather than
  /// fishing out individual `CGFloat`s.
  private static func fetchWindowBoundsPts(windowID: CGWindowID) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo(
      .optionIncludingWindow, windowID) as? [[String: Any]]
    else { return nil }
    for info in list {
      let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
      guard id == windowID else { continue }
      guard let boundsAny = info[kCGWindowBounds as String],
            let boundsDict = boundsAny as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: boundsDict)
      else { continue }
      return rect
    }
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

  private func pickSource(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let kindStr = (args?["kind"] as? String) ?? "window"
    let kind: PickerKind = (kindStr == "screen") ? .screen : .window
    Task { @MainActor in
      let picked = await SourcePickerOverlay.shared.pick(kind: kind)
      if let p = picked {
        result([
          "kind": p.kind == .window ? "window" : "screen",
          "id": p.id,
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
        result(Self.classifyListSourcesError(error))
      }
    }
  }

  /// Map a `SCShareableContent` failure to a stable `FlutterError` code.
  ///
  /// `SCShareableContent` throws when the user has not granted the
  /// Screen Recording (TCC) entitlement. Apple's error wording — and
  /// even its localised description — drifts across OS versions ("The
  /// user declined TCCs..." on Sequoia, "Screen recording permission
  /// denied..." on Sonoma, etc.), so the Dart side cannot reliably
  /// substring-match on the message. Instead we surface a fixed
  /// `PERMISSION_DENIED` code here and leave the freeform message in
  /// place for diagnostics.
  ///
  /// We detect TCC denial in two ways:
  ///   1. NSError domain that mentions ScreenCaptureKit — covers
  ///      `SCStreamErrorDomain` and any future near-equivalents.
  ///   2. A `tcc` / `declined` / `permission` keyword in the localised
  ///      description — belt-and-suspenders in case Apple ever throws
  ///      a domain-less error.
  private static func classifyListSourcesError(_ error: Error) -> FlutterError {
    let ns = error as NSError
    let domain = ns.domain
    let desc = ns.localizedDescription.lowercased()
    let looksLikeTcc =
        domain.contains("ScreenCaptureKit") ||
        desc.contains("tcc") ||
        desc.contains("declined") ||
        desc.contains("permission")
    if looksLikeTcc {
      return FlutterError(code: "PERMISSION_DENIED",
                          message: ns.localizedDescription,
                          details: nil)
    }
    return FlutterError(code: "DISCOVERY_FAILED",
                        message: "listSources failed: \(ns.localizedDescription)",
                        details: nil)
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

// MARK: - Microphone Menu Target

private final class MicMenuTarget: NSObject {
  enum Action { case device(uid: String, label: String), toggleReduceNoise, toggleDisableAgc, dontRecord }
  var action: Action?
  @objc func pickDevice(_ s: NSMenuItem) {
    if let pair = s.representedObject as? [String: String] {
      action = .device(uid: pair["uid"] ?? "", label: pair["label"] ?? "")
    }
  }
  @objc func toggleReduceNoise(_ s: NSMenuItem) { action = .toggleReduceNoise }
  @objc func toggleDisableAgc(_ s: NSMenuItem) { action = .toggleDisableAgc }
  @objc func dontRecord(_ s: NSMenuItem) { action = .dontRecord }
}

// MARK: - System Audio Menu Target

@available(macOS 13.0, *)
final class SysAudioMenuTarget: NSObject {
  enum Action { case none, all, dontRecord }
  var action: Action = .none
  @objc func pickAll(_ s: Any) { action = .all }
  @objc func dontRecord(_ s: Any) { action = .dontRecord }
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

  func sendCursorPosition(
    x: Double, y: Double, timestamp: Int64, isClicked: Bool, state: String = "arrow"
  ) {
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
      "isClicked": isClicked,
      "state": state
    ]

    DispatchQueue.main.async {
      eventSink(cursorData)
    }

    sampleCount += 1
  }
}

// MARK: - Mic Level Stream Handler

class MicLevelStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  /// Called on the main thread by MicLevelMonitor.
  func send(_ level: Double) {
    guard let sink = eventSink, level.isFinite else { return }
    sink(level)
  }
}
