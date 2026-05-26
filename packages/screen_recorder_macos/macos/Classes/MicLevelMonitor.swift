import Foundation
import AVFoundation
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
  private var lastStart: CFTimeInterval = 0

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
      if let uid = deviceUid, let devID = AudioDeviceCatalog.deviceID(forUID: uid) {
        do { try input.auAudioUnit.setDeviceID(devID) }
        catch { NSLog("MicLevelMonitor: setDeviceID(\(uid)) failed: \(error)") }
      }
      // Voice processing is sticky on the input node, so set it explicitly both
      // ways (a previous reduceNoise=true session would otherwise leak in).
      try input.setVoiceProcessingEnabled(reduceNoise)
      if reduceNoise, #available(macOS 14.0, *) {
        input.isVoiceProcessingAGCEnabled = !disableAgc
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
      try engine.start()
      self.engine = engine
      self.isRunning = true
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
    if let obs = configObserver {
      NotificationCenter.default.removeObserver(obs)
      configObserver = nil
    }
    guard isRunning, let engine = engine else { return }
    isRunning = false
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
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
      NSLog("MicLevelMonitor: configuration changed — rebuilding tap")
      self.start(deviceUid: self.deviceUid,
                 reduceNoise: self.reduceNoise,
                 disableAgc: self.disableAgc)
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
    DispatchQueue.main.async { [weak self] in self?.onLevel?(out) }
  }
}
