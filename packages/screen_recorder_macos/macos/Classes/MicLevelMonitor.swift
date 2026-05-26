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

  /// Start monitoring [deviceUid] (nil → default input). [reduceNoise] mirrors
  /// the recorder so the meter reflects the processed signal.
  func start(deviceUid: String?, reduceNoise: Bool, disableAgc: Bool) {
    stop()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    smoothed = 0
    lastEmit = 0
    do {
      if let uid = deviceUid, let devID = AudioDeviceCatalog.deviceID(forUID: uid) {
        do { try input.auAudioUnit.setDeviceID(devID) } catch { /* fall back to default */ }
      }
      // Voice processing is sticky on the input node, so set it explicitly both
      // ways (a previous reduceNoise=true session would otherwise leak in).
      try input.setVoiceProcessingEnabled(reduceNoise)
      if reduceNoise, #available(macOS 14.0, *) {
        input.isVoiceProcessingAGCEnabled = !disableAgc
      }
      let format = input.outputFormat(forBus: 0)
      input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
        self?.process(buffer)
      }
      try engine.start()
      self.engine = engine
      self.isRunning = true
    } catch {
      input.removeTap(onBus: 0)
      engine.stop()
    }
  }

  func stop() {
    guard isRunning, let engine = engine else { return }
    isRunning = false
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
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

    // Attack/decay smoothing: rise fast, fall slower.
    let coeff = level > smoothed ? 0.5 : 0.15
    smoothed += (level - smoothed) * coeff

    // Throttle to ~20 Hz.
    let now = CACurrentMediaTime()
    guard now - lastEmit >= 0.05 else { return }
    lastEmit = now
    let out = smoothed
    DispatchQueue.main.async { [weak self] in self?.onLevel?(out) }
  }
}
