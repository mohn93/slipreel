import Foundation
import VideoToolbox
import CoreVideo
import AVFoundation

/// Hardware-accelerated H.264 encoder using VideoToolbox
/// NOTE: This is architectural foundation for Phase 9 (future work).
/// Current implementation uses FFmpeg for complete encoding pipeline.
class VideoToolboxEncoder {
  private var compressionSession: VTCompressionSession?
  private var outputFileHandle: FileHandle?
  private var outputURL: URL?

  private let width: Int
  private let height: Int
  private let fps: Int
  private var frameCount: Int64 = 0

  init(width: Int, height: Int, fps: Int) {
    self.width = width
    self.height = height
    self.fps = fps
  }

  /// Initialize the encoder
  func initialize(outputPath: String) throws {
    outputURL = URL(fileURLWithPath: outputPath)

    // Create output file
    FileManager.default.createFile(atPath: outputPath, contents: nil)
    outputFileHandle = try FileHandle(forWritingTo: outputURL!)

    // Create compression session
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(width),
      height: Int32(height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: nil,
      refcon: nil,
      compressionSessionOut: &session
    )

    guard status == noErr, let session = session else {
      throw NSError(
        domain: "VideoToolboxEncoder",
        code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "Failed to create compression session"]
      )
    }

    compressionSession = session

    // Configure encoding properties
    VTSessionSetProperty(
      session,
      key: kVTCompressionPropertyKey_RealTime,
      value: kCFBooleanTrue
    )

    VTSessionSetProperty(
      session,
      key: kVTCompressionPropertyKey_ProfileLevel,
      value: kVTProfileLevel_H264_Main_AutoLevel
    )

    VTSessionSetProperty(
      session,
      key: kVTCompressionPropertyKey_ExpectedFrameRate,
      value: NSNumber(value: fps)
    )

    VTSessionSetProperty(
      session,
      key: kVTCompressionPropertyKey_AverageBitRate,
      value: NSNumber(value: width * height * 8) // 8 bits per pixel
    )

    // Prepare to encode
    VTCompressionSessionPrepareToEncodeFrames(session)
  }

  /// Encode a frame
  func encodeFrame(pixelBuffer: CVPixelBuffer, timestamp: CMTime) throws {
    guard let session = compressionSession else {
      throw NSError(
        domain: "VideoToolboxEncoder",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Compression session not initialized"]
      )
    }

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

    guard status == noErr else {
      throw NSError(
        domain: "VideoToolboxEncoder",
        code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "Failed to encode frame"]
      )
    }

    frameCount += 1
  }

  /// Finalize encoding
  func finalize() throws {
    guard let session = compressionSession else { return }

    // Finish encoding
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

    // Invalidate session
    VTCompressionSessionInvalidate(session)
    compressionSession = nil

    // Close file
    try? outputFileHandle?.close()
    outputFileHandle = nil
  }

  deinit {
    if let session = compressionSession {
      VTCompressionSessionInvalidate(session)
    }
    try? outputFileHandle?.close()
  }
}
