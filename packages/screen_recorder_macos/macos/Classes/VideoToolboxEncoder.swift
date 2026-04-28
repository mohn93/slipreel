// packages/screen_recorder_macos/macos/Classes/VideoToolboxEncoder.swift
import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia

/// Hardware-accelerated H.264 encoder using VideoToolbox.
///
/// Receives raw `CVPixelBuffer`s from the capture stream, hands them to a
/// `VTCompressionSession`, and forwards each compressed `CMSampleBuffer` to
/// the configured output handler (typically `LiveRecordingWriter.appendVideo`).
class VideoToolboxEncoder {
  enum EncoderError: LocalizedError {
    case sessionCreateFailed(OSStatus)
    case hardwareUnavailable
    case configFailed(OSStatus)
    case encodeFailed(OSStatus)
    case notInitialized

    var errorDescription: String? {
      switch self {
      case .sessionCreateFailed(let s):
        return "VTCompressionSessionCreate failed (status \(s))"
      case .hardwareUnavailable:
        return "Hardware H.264 encoder is not available on this Mac"
      case .configFailed(let s):
        return "VTSessionSetProperty failed (status \(s))"
      case .encodeFailed(let s):
        return "VTCompressionSessionEncodeFrame failed (status \(s))"
      case .notInitialized:
        return "VideoToolboxEncoder used before initialize()"
      }
    }
  }

  private var compressionSession: VTCompressionSession?
  private let width: Int
  private let height: Int
  private let fps: Int

  /// Called for each compressed sample. Set before initialize().
  var onCompressedSample: ((CMSampleBuffer) -> Void)?

  /// Atomically tracks frames the encoder reported as dropped via
  /// `kVTEncodeInfo_FrameDropped`. Read at stop time.
  private(set) var droppedFrameCount: Int = 0

  init(width: Int, height: Int, fps: Int) {
    self.width = width
    self.height = height
    self.fps = fps
  }

  func initialize() throws {
    let bitsPerPixel = 0.1 // ~6 Mbps at 1080p30, ~12 Mbps at 1080p60
    let bitrate = Int(Double(width * height * fps) * bitsPerPixel)

    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(width),
      height: Int32(height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue,
      ] as CFDictionary,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: VideoToolboxEncoder.outputCallback,
      refcon: Unmanaged.passUnretained(self).toOpaque(),
      compressionSessionOut: &session
    )

    guard status == noErr, let session = session else {
      if status == kVTCouldNotFindVideoEncoderErr {
        throw EncoderError.hardwareUnavailable
      }
      throw EncoderError.sessionCreateFailed(status)
    }
    compressionSession = session

    try setProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    try setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    try setProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
    try setProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
    try setProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
    try setProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))

    VTCompressionSessionPrepareToEncodeFrames(session)
  }

  private func setProperty(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) throws {
    let status = VTSessionSetProperty(session, key: key, value: value)
    if status != noErr { throw EncoderError.configFailed(status) }
  }

  func encode(pixelBuffer: CVPixelBuffer, timestamp: CMTime) throws {
    guard let session = compressionSession else { throw EncoderError.notInitialized }
    var flags = VTEncodeInfoFlags()
    let status = VTCompressionSessionEncodeFrame(
      session,
      imageBuffer: pixelBuffer,
      presentationTimeStamp: timestamp,
      duration: .invalid,
      frameProperties: nil,
      sourceFrameRefcon: nil,
      infoFlagsOut: &flags
    )
    if status != noErr { throw EncoderError.encodeFailed(status) }
    if flags.contains(.frameDropped) { droppedFrameCount += 1 }
  }

  func finalize() {
    guard let session = compressionSession else { return }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(session)
    compressionSession = nil
  }

  deinit { finalize() }

  // MARK: - Output callback

  private static let outputCallback: VTCompressionOutputCallback = {
    (refcon, sourceFrameRefcon, status, infoFlags, sampleBuffer) in
    guard status == noErr else {
      NSLog("[VideoToolboxEncoder] encode error: \(status)")
      return
    }
    guard let sampleBuffer = sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }
    guard let refcon = refcon else { return }
    let encoder = Unmanaged<VideoToolboxEncoder>.fromOpaque(refcon).takeUnretainedValue()
    encoder.onCompressedSample?(sampleBuffer)
  }
}
