import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Handles encoding video frames to MP4 using FFmpeg
class VideoEncoder {
  String? _tempDir;
  String? _outputPath;
  int _width = 0;
  int _height = 0;
  int _fps = 30;
  int _frameIndex = 0;
  int _audioSampleIndex = 0;
  bool _isInitialized = false;
  int? _audioSampleRate;
  int? _audioChannels;

  /// Initialize the encoder with output settings
  Future<void> initialize({
    required String outputPath,
    required int width,
    required int height,
    required int fps,
  }) async {
    _outputPath = outputPath;
    _width = width;
    _height = height;
    _fps = fps;

    // Create temporary directory for frames
    final tempBaseDir = await getTemporaryDirectory();
    _tempDir = '${tempBaseDir.path}/screenflow_frames_${DateTime.now().millisecondsSinceEpoch}';
    await Directory(_tempDir!).create(recursive: true);

    _frameIndex = 0;
    _isInitialized = true;

    print('VideoEncoder initialized: ${_width}x$_height @ ${_fps}fps');
    print('Temp dir: $_tempDir');
    print('Output: $_outputPath');
  }

  /// Add a frame to the video
  Future<void> addFrame(FrameData frameData) async {
    if (!_isInitialized) {
      throw StateError('VideoEncoder not initialized. Call initialize() first.');
    }

    // Update dimensions if first frame
    if (_frameIndex == 0) {
      _width = frameData.width;
      _height = frameData.height;
    }

    // Save frame as raw BGRA file
    // We'll convert these to a video using FFmpeg later
    final framePath = '$_tempDir/frame_${_frameIndex.toString().padLeft(6, '0')}.bgra';
    final file = File(framePath);
    await file.writeAsBytes(frameData.data);

    _frameIndex++;

    if (_frameIndex % 30 == 0) {
      print('Saved frame $_frameIndex');
    }
  }

  /// Add an audio sample to the recording
  Future<void> addAudioSample(Uint8List audioData, int sampleRate, int channels) async {
    if (!_isInitialized) {
      throw StateError('VideoEncoder not initialized. Call initialize() first.');
    }

    // Store audio format on first sample
    if (_audioSampleRate == null) {
      _audioSampleRate = sampleRate;
      _audioChannels = channels;
      print('Audio format: $sampleRate Hz, $channels channels');
    }

    // Save audio sample as individual PCM file
    final audioPath = '$_tempDir/audio_${_audioSampleIndex.toString().padLeft(6, '0')}.pcm';
    final file = File(audioPath);
    await file.writeAsBytes(audioData);

    _audioSampleIndex++;

    if (_audioSampleIndex % 100 == 0) {
      print('Saved audio sample $_audioSampleIndex');
    }
  }

  /// Finalize the video by encoding all frames to MP4
  Future<String> finalize() async {
    if (!_isInitialized) {
      throw StateError('VideoEncoder not initialized');
    }

    if (_frameIndex == 0) {
      throw StateError('No frames to encode');
    }

    print('Finalizing video: $_frameIndex frames, $_audioSampleIndex audio samples');

    // Concatenate audio samples if we have any
    String? combinedAudioPath;
    if (_audioSampleIndex > 0 && _audioSampleRate != null && _audioChannels != null) {
      print('Concatenating audio samples...');
      combinedAudioPath = '$_tempDir/audio_combined.pcm';
      final combinedFile = File(combinedAudioPath);
      final sink = combinedFile.openWrite();

      try {
        for (int i = 0; i < _audioSampleIndex; i++) {
          final audioPath = '$_tempDir/audio_${i.toString().padLeft(6, '0')}.pcm';
          final audioFile = File(audioPath);
          if (await audioFile.exists()) {
            final audioData = await audioFile.readAsBytes();
            sink.add(audioData);
          }
        }
        await sink.flush();
        await sink.close();
        print('Audio concatenation complete');
      } catch (e) {
        print('Error concatenating audio: $e');
        await sink.close();
        combinedAudioPath = null;
      }
    }

    // Build FFmpeg command
    List<String> args;

    if (combinedAudioPath != null) {
      // Mux video + audio
      args = [
        // Video input
        '-f', 'rawvideo',
        '-pix_fmt', 'bgra',
        '-s', '${_width}x$_height',
        '-r', '$_fps',
        '-i', '$_tempDir/frame_%06d.bgra',
        // Audio input
        '-f', 's16le',
        '-ar', '$_audioSampleRate',
        '-ac', '$_audioChannels',
        '-i', combinedAudioPath,
        // Video codec
        '-c:v', 'libx264',
        '-preset', 'fast',
        '-crf', '23',
        '-pix_fmt', 'yuv420p',
        // Audio codec
        '-c:a', 'aac',
        '-b:a', '192k',
        // Sync options
        '-vsync', 'cfr',
        '-async', '1',
        '-y',
        _outputPath!,
      ];
      print('Encoding with audio and video');
    } else {
      // Video only (original behavior)
      args = [
        '-f', 'rawvideo',
        '-pix_fmt', 'bgra',
        '-s', '${_width}x$_height',
        '-r', '$_fps',
        '-i', '$_tempDir/frame_%06d.bgra',
        '-c:v', 'libx264',
        '-preset', 'fast',
        '-crf', '23',
        '-pix_fmt', 'yuv420p',
        '-y',
        _outputPath!,
      ];
      print('Encoding video only (no audio)');
    }

    print('FFmpeg command: ffmpeg ${args.join(" ")}');

    try {
      // Execute FFmpeg using system command
      final result = await Process.run('ffmpeg', args);

      if (result.exitCode == 0) {
        print('Video encoding successful!');
        print('Output file: $_outputPath');

        // Check file size
        final outputFile = File(_outputPath!);
        if (await outputFile.exists()) {
          final sizeBytes = await outputFile.length();
          final sizeMB = sizeBytes / (1024 * 1024);
          print('File size: ${sizeMB.toStringAsFixed(2)} MB');
        }
      } else {
        print('FFmpeg failed with exit code ${result.exitCode}');
        print('stdout: ${result.stdout}');
        print('stderr: ${result.stderr}');
        throw Exception('Failed to encode video: exit code ${result.exitCode}');
      }
    } on ProcessException catch (e) {
      print('FFmpeg not found or failed to run: $e');
      throw Exception('FFmpeg is not installed or not in PATH. Please install FFmpeg.');
    }

    // Cleanup temporary files
    await _cleanup();

    return _outputPath!;
  }

  /// Clean up temporary frame files
  Future<void> _cleanup() async {
    if (_tempDir != null) {
      try {
        final dir = Directory(_tempDir!);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          print('Cleaned up temporary files');
        }
      } catch (e) {
        print('Error cleaning up temp files: $e');
      }
    }

    _isInitialized = false;
  }

  /// Cancel encoding and cleanup
  Future<void> cancel() async {
    await _cleanup();
  }

  /// Get the number of frames added
  int get frameCount => _frameIndex;

  /// Check if encoder is initialized
  bool get isInitialized => _isInitialized;
}
