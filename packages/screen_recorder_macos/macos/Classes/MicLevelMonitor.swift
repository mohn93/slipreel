import Foundation
import AVFoundation
import CoreAudio
import QuartzCore

/// Lightweight live mic monitor: taps the selected input device, computes a
/// smoothed 0..1 RMS level, and reports it (~20 Hz) via `onLevel`. Separate
/// from AudioCaptureManager so the recording lifecycle stays untangled.
final class MicLevelMonitor {
  var onLevel: ((Double) -> Void)?

  private var engine: AVAudioEngine?
  private var smoothed: Double = 0
  private var lastEmit: CFTimeInterval = 0
  private(set) var isRunning = false

  // Stored so the monitor can rebuild itself on an engine configuration change.
  private var deviceUid: String?
  private var reduceNoise = false
  private var disableAgc = false
  private var configObserver: NSObjectProtocol?
  private var pendingConfigRestart: DispatchWorkItem?
  private var lastStart: CFTimeInterval = 0
  private var healthTimer: DispatchSourceTimer?
  private var lastBufferAt: CFTimeInterval = 0
  private var healthProblemReported = false
  private var expectedDeviceID: AudioDeviceID?

  // Audio amplitude can legitimately be zero. Health is based on whether the
  // tap continues delivering buffers, regardless of their sample values.
  private static let bufferTimeout: CFTimeInterval = 2.5

  /// Start monitoring [deviceUid] (nil → default input). [reduceNoise] mirrors
  /// the recorder so the meter reflects the processed signal.
  func start(deviceUid: String?, reduceNoise: Bool, disableAgc: Bool) {
    stop()
    self.deviceUid = deviceUid
    self.reduceNoise = reduceNoise
    self.disableAgc = disableAgc
    lastStart = CACurrentMediaTime()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    smoothed = 0
    lastEmit = 0
    do {
      // Voice processing can rebuild the I/O unit and reset its route, so apply
      // it before binding and verifying the user's explicit device.
      try input.setVoiceProcessingEnabled(reduceNoise)
      if reduceNoise, #available(macOS 14.0, *) {
        input.isVoiceProcessingAGCEnabled = !disableAgc
      }

      var selectedDeviceID: AudioDeviceID?
      if let uid = deviceUid {
        // The selected device must still be present. If its UID no longer
        // resolves (e.g. a Continuity mic whose iPhone disconnected), do NOT
        // silently fall through to the default input — that leaves the bar
        // showing the wrong device with no audio from the one the user picked.
        // Treat it as a failed start so the catch below emits the -1 sentinel.
        guard let devID = AudioDeviceCatalog.deviceID(forUID: uid) else {
          throw NSError(
            domain: "MicLevelMonitor", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "selected input '\(uid)' is unavailable"])
        }
        // AVAudioEngine owns a private aggregate for the system-default input
        // and output. Forcing the physical default input onto its audio unit can
        // report success while producing no buffers. Leave the default route
        // alone; the route check after startup confirms its aggregate represents
        // this physical device. Non-default inputs still need explicit binding.
        if !AudioDeviceCatalog.isDefaultInputDevice(devID) {
          try input.auAudioUnit.setDeviceID(devID)
          guard input.auAudioUnit.deviceID == devID else {
            throw NSError(
              domain: "MicLevelMonitor", code: -3,
              userInfo: [NSLocalizedDescriptionKey: "selected input '\(uid)' was not activated"])
          }
        }
        selectedDeviceID = devID
      }
      // A freshly-switched device can momentarily report an invalid (0 Hz / 0
      // channel) format; installing a tap or starting the engine on it throws,
      // which previously left the meter frozen at a stale value. Treat it as a
      // failed start so we fall through to the recovery path below.
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        throw NSError(
          domain: "MicLevelMonitor", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "invalid input format \(format)"])
      }
      input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
        self?.process(buffer)
      }
      engine.prepare()
      try engine.start()
      if let selectedDeviceID,
         !AudioDeviceCatalog.route(input.auAudioUnit.deviceID, contains: selectedDeviceID) {
        throw NSError(
          domain: "MicLevelMonitor", code: -3,
          userInfo: [NSLocalizedDescriptionKey: "selected input route changed during startup"])
      }
      self.engine = engine
      self.isRunning = true
      self.expectedDeviceID = selectedDeviceID
      resetBufferHealth(at: CACurrentMediaTime())
      startHealthWatchdog()
      observeConfigChanges(of: engine)
    } catch {
      NSLog("MicLevelMonitor: start failed: \(error)")
      input.removeTap(onBus: 0)
      engine.stop()
      // Report a negative sentinel so the UI shows a problem indicator instead
      // of freezing at a stale value or looking like plain silence.
      DispatchQueue.main.async { [weak self] in self?.onLevel?(-1) }
    }
  }

  func stop() {
    cancelHealthWatchdog()
    pendingConfigRestart?.cancel()
    pendingConfigRestart = nil
    if let obs = configObserver {
      NotificationCenter.default.removeObserver(obs)
      configObserver = nil
    }
    guard isRunning, let engine = engine else { return }
    isRunning = false
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
    expectedDeviceID = nil
    // Clear the meter when monitoring ends (e.g. switching devices) so a stale
    // level never lingers while the next engine spins up.
    DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
  }

  /// AVAudioEngine stops itself when the audio configuration changes — the
  /// input device's sample rate/route changes, or another app grabs it. The
  /// installed tap then goes silent with no error, freezing the meter. Observe
  /// that and rebuild the tap so the meter keeps tracking.
  private func observeConfigChanges(of engine: AVAudioEngine) {
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, self.isRunning else { return }
      // Ignore the churn that voice-processing setup itself triggers right
      // after a start(), so we don't loop restarting.
      guard CACurrentMediaTime() - self.lastStart > 0.5 else { return }
      // Core Audio posts this while constructing/updating AVAudioEngine's
      // default aggregate. If the engine is still running, rebuilding here
      // creates a self-sustaining restart loop and the input never settles.
      guard !engine.isRunning else { return }

      self.pendingConfigRestart?.cancel()
      let restart = DispatchWorkItem { [weak self, weak engine] in
        guard let self, let engine,
              self.engine === engine, !engine.isRunning else { return }
        NSLog("MicLevelMonitor: stopped after configuration change — rebuilding tap")
        self.start(deviceUid: self.deviceUid,
                   reduceNoise: self.reduceNoise,
                   disableAgc: self.disableAgc)
      }
      self.pendingConfigRestart = restart
      DispatchQueue.main.asyncAfter(
        deadline: .now() + .milliseconds(250), execute: restart)
    }
  }

  private func process(_ buffer: AVAudioPCMBuffer) {
    guard isRunning else { return }
    guard let ch = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    guard frames > 0, channels > 0 else { return }

    // RMS across all channels.
    var sumSquares: Double = 0
    for c in 0..<channels {
      let data = ch[c]
      for i in 0..<frames { let s = Double(data[i]); sumSquares += s * s }
    }
    let rms = (sumSquares / Double(frames * channels)).squareRoot()

    // RMS → dBFS → 0..1 over a -60..0 dB window.
    let db = rms > 0 ? 20 * log10(rms) : -160
    let level = max(0, min(1, (db + 60) / 60))

    // Light attack/decay smoothing only — the Flutter spring does the visual
    // smoothing. Keep the fall fast so the fill drops promptly when you go
    // quiet, letting the peak-hold marker visibly lead it back down.
    let coeff = level > smoothed ? 0.5 : 0.45
    smoothed += (level - smoothed) * coeff

    // Throttle to ~20 Hz.
    let now = CACurrentMediaTime()
    guard now - lastEmit >= 0.05 else { return }
    lastEmit = now
    let out = smoothed
    DispatchQueue.main.async { [weak self] in self?.receiveBufferLevel(out) }
  }

  private func resetBufferHealth(at time: CFTimeInterval) {
    lastBufferAt = time
    healthProblemReported = false
  }

  /// Runs on the main queue with the watchdog. A zero [level] still counts as
  /// healthy because receiving a valid buffer—not its amplitude—is the signal.
  private func receiveBufferLevel(_ level: Double) {
    guard isRunning, let engine = engine else { return }
    if let expectedDeviceID,
       !AudioDeviceCatalog.route(
         engine.inputNode.auAudioUnit.deviceID, contains: expectedDeviceID) {
      return
    }
    lastBufferAt = CACurrentMediaTime()
    healthProblemReported = false
    onLevel?(level)
  }

  private func startHealthWatchdog() {
    cancelHealthWatchdog()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now() + .milliseconds(500),
      repeating: .milliseconds(500),
      leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in self?.checkBufferHealth() }
    healthTimer = timer
    timer.resume()
  }

  private func cancelHealthWatchdog() {
    healthTimer?.setEventHandler {}
    healthTimer?.cancel()
    healthTimer = nil
  }

  private func checkBufferHealth() {
    guard isRunning, let engine = engine else { return }
    let now = CACurrentMediaTime()
    // A mismatched route's buffers are rejected by receiveBufferLevel, so it
    // naturally becomes a timeout. This grace period also gives Core Audio time
    // to finish publishing a newly-created aggregate's sub-device list.
    let stalled = !engine.isRunning || now - lastBufferAt > Self.bufferTimeout
    let shouldReport = stalled && !healthProblemReported
    healthProblemReported = stalled

    if shouldReport {
      let actualID = engine.inputNode.auAudioUnit.deviceID
      NSLog("MicLevelMonitor: selected input route is no longer healthy (expected=\(expectedDeviceID ?? 0), actual=\(actualID))")
      onLevel?(-1)
    }
  }
}
