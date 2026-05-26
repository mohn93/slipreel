import Foundation
import ScreenCaptureKit
import CoreMedia

/// Capture mode for system audio.
enum SystemAudioMode: String { case allApps, selectedApps }

/// Captures system/app audio via a DEDICATED audio-only SCStream, independent
/// of the video capture stream, so the audio app-scope is decoupled from what
/// video is being recorded. Emits CMSampleBuffers via `onSampleBufferReceived`.
/// macOS 13.0+ (capturesAudio / excludesCurrentProcessAudio).
@available(macOS 13.0, *)
final class SystemAudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
  var onSampleBufferReceived: ((CMSampleBuffer) -> Void)?

  private var stream: SCStream?
  private let audioQueue = DispatchQueue(label: "com.slipreel.systemaudio")

  /// Start capturing. `mode == .selectedApps` uses `bundleIds`; if no running
  /// app matches, throws (caller treats system audio as unavailable and drops
  /// the track — recording continues).
  func start(mode: SystemAudioMode, bundleIds: [String]) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard let display = content.displays.first else {
      throw NSError(domain: "SystemAudioCaptureManager", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "no display available"])
    }

    let filter: SCContentFilter
    switch mode {
    case .allApps:
      filter = SCContentFilter(
        display: display, excludingApplications: [], exceptingWindows: [])
    case .selectedApps:
      let chosen = content.applications.filter {
        bundleIds.contains($0.bundleIdentifier)
      }
      guard !chosen.isEmpty else {
        throw NSError(domain: "SystemAudioCaptureManager", code: -2,
          userInfo: [NSLocalizedDescriptionKey: "no selected app is running"])
      }
      filter = SCContentFilter(
        display: display, including: chosen, exceptingWindows: [])
    }

    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 48000
    config.channelCount = 2
    // We never consume video; keep the dummy video tiny.
    config.width = 2
    config.height = 2

    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
    try await stream.startCapture()
    self.stream = stream
  }

  func stop() {
    stream?.stopCapture { _ in }
    stream = nil
  }

  // MARK: SCStreamOutput
  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
              of type: SCStreamOutputType) {
    guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
    onSampleBufferReceived?(sampleBuffer)
  }

  // MARK: SCStreamDelegate
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    NSLog("SystemAudioCaptureManager: stream stopped: \(error)")
  }
}
