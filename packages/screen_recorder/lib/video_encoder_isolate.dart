import 'dart:typed_data';
import 'processing/video_processing_isolate.dart';

/// Video encoder that uses background isolate for processing
///
/// This is a drop-in replacement for VideoEncoder that performs
/// all encoding work on a background isolate to prevent UI blocking.
class VideoEncoderIsolate {
  VideoProcessingIsolate? _isolate;
  int _frameCount = 0;
  bool _isInitialized = false;

  /// Progress callback for encoding updates
  void Function(double)? onProgress;

  bool get isInitialized => _isInitialized;
  int get frameCount => _frameCount;

  // TODO: Background effects not yet supported in VideoEncoderIsolate
  // Currently only works with legacy VideoEncoder
  // Will be integrated in future phase

  /// Initialize the encoder with output settings
  Future<void> initialize({
    required String outputPath,
    required int width,
    required int height,
    required int fps,
  }) async {
    _frameCount = 0;

    _isolate = VideoProcessingIsolate();
    await _isolate!.initialize();

    _isolate!.onProgress = (progress) {
      onProgress?.call(progress);
    };

    await _isolate!.configureEncoder(
      outputPath: outputPath,
      width: width,
      height: height,
      fps: fps,
    );

    _isInitialized = true;
  }

  /// Add a frame to the video
  Future<void> addFrame(Uint8List frameData, int timestampMicros) async {
    if (!_isInitialized) {
      throw StateError('Encoder not initialized');
    }

    await _isolate!.processFrame(frameData, timestampMicros);
    _frameCount++;
  }

  /// Finalize the video and return output path
  Future<String> finalize() async {
    if (!_isInitialized) {
      throw StateError('Encoder not initialized');
    }

    final outputPath = await _isolate!.finalize(_frameCount);
    await _isolate?.dispose();
    _isolate = null;
    _isInitialized = false;
    // Keep _frameCount for inspection after finalization
    return outputPath;
  }

  /// Cancel encoding and cleanup
  Future<void> cancel() async {
    if (!_isInitialized) {
      // Nothing to cancel if not initialized
      return;
    }
    await _dispose();
  }

  Future<void> _dispose() async {
    await _isolate?.dispose();
    _isolate = null;
    _isInitialized = false;
    _frameCount = 0;
  }
}
