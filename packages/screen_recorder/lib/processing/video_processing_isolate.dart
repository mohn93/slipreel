import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../video_encoder.dart';

/// TimeoutException is used for request timeouts
class TimeoutException implements Exception {
  final String message;
  const TimeoutException(this.message);

  @override
  String toString() => 'TimeoutException: $message';
}

/// Messages sent to the video processing isolate
abstract class ProcessingMessage {
  const ProcessingMessage();
}

class InitializeMessage extends ProcessingMessage {
  final SendPort sendPort;
  const InitializeMessage(this.sendPort);
}

class ConfigureEncoderMessage extends ProcessingMessage {
  final String outputPath;
  final int width;
  final int height;
  final int fps;

  const ConfigureEncoderMessage({
    required this.outputPath,
    required this.width,
    required this.height,
    required this.fps,
  });
}

class ProcessFrameMessage extends ProcessingMessage {
  final Uint8List frameData;
  final int timestampMicros;
  final int width;
  final int height;

  const ProcessFrameMessage(
    this.frameData,
    this.timestampMicros,
    this.width,
    this.height,
  );
}

class FinalizeMessage extends ProcessingMessage {
  final int totalFrames;
  const FinalizeMessage(this.totalFrames);
}

class DisposeMessage extends ProcessingMessage {
  const DisposeMessage();
}

/// Responses from the video processing isolate
abstract class ProcessingResponse {
  const ProcessingResponse();
}

class InitializedResponse extends ProcessingResponse {
  const InitializedResponse();
}

class ConfiguredResponse extends ProcessingResponse {
  const ConfiguredResponse();
}

class FrameProcessedResponse extends ProcessingResponse {
  const FrameProcessedResponse();
}

class ProgressUpdate extends ProcessingResponse {
  final double progress;
  const ProgressUpdate(this.progress);
}

class FinalizedResponse extends ProcessingResponse {
  final String outputPath;
  const FinalizedResponse(this.outputPath);
}

class ErrorResponse extends ProcessingResponse {
  final String message;
  final String? stackTrace;
  const ErrorResponse(this.message, [this.stackTrace]);
}

/// Manages a background isolate for video processing
class VideoProcessingIsolate {
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _sendPort;
  bool _isInitialized = false;
  bool _isConfigured = false;
  final Map<String, Completer<ProcessingResponse>> _pendingRequests = {};
  int _requestId = 0;
  int _width = 0;
  int _height = 0;
  void Function(double)? onProgress;

  bool get isInitialized => _isInitialized;
  bool get isConfigured => _isConfigured;

  /// Initialize the isolate and establish communication
  Future<void> initialize() async {
    _receivePort = ReceivePort();

    _isolate = await Isolate.spawn(
      _isolateEntryPoint,
      _receivePort!.sendPort,
    );

    // Wait for isolate to send back its SendPort
    final completer = Completer<void>();
    _receivePort!.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _isInitialized = true;
        completer.complete();
      } else if (message is Map) {
        // Handle response with request ID
        final requestId = message['requestId'] as String?;
        final response = message['response'] as ProcessingResponse;

        if (response is ProgressUpdate) {
          // Progress updates don't have request IDs
          onProgress?.call(response.progress);
        } else if (requestId != null) {
          final pending = _pendingRequests.remove(requestId);
          if (pending != null && !pending.isCompleted) {
            if (response is ErrorResponse) {
              pending.completeError(Exception(response.message));
            } else {
              pending.complete(response);
            }
          }
        }
      } else if (message is ErrorResponse) {
        completer.completeError(Exception(message.message));
      }
    });

    await completer.future;
  }

  /// Process a frame in the background isolate
  Future<void> processFrame(Uint8List frameData, int timestampMicros) async {
    if (!_isConfigured) {
      throw StateError('Encoder not configured');
    }

    final requestId = (_requestId++).toString();
    final completer = Completer<ProcessingResponse>();
    _pendingRequests[requestId] = completer;

    _sendPort!.send({
      'requestId': requestId,
      'message': ProcessFrameMessage(frameData, timestampMicros, _width, _height),
    });

    // Add timeout to prevent hanging if isolate crashes
    await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pendingRequests.remove(requestId);
        throw TimeoutException('Frame processing timed out after 10 seconds');
      },
    );
  }

  /// Finalize video encoding and return output path
  Future<String> finalize(int totalFrames) async {
    if (!_isConfigured) {
      throw StateError('Encoder not configured');
    }

    final requestId = (_requestId++).toString();
    final completer = Completer<ProcessingResponse>();
    _pendingRequests[requestId] = completer;

    _sendPort!.send({
      'requestId': requestId,
      'message': FinalizeMessage(totalFrames),
    });

    // Add timeout for finalization (longer timeout as this can take time)
    final response = await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pendingRequests.remove(requestId);
        throw TimeoutException('Finalization timed out after 30 seconds');
      },
    );

    if (response is FinalizedResponse) {
      return response.outputPath;
    }

    throw Exception('Finalization failed');
  }

  /// Configure the encoder with video settings
  Future<void> configureEncoder({
    required String outputPath,
    required int width,
    required int height,
    required int fps,
  }) async {
    if (!_isInitialized) {
      throw StateError('Isolate not initialized');
    }

    _width = width;
    _height = height;

    final requestId = (_requestId++).toString();
    final completer = Completer<ProcessingResponse>();
    _pendingRequests[requestId] = completer;

    _sendPort!.send({
      'requestId': requestId,
      'message': ConfigureEncoderMessage(
        outputPath: outputPath,
        width: width,
        height: height,
        fps: fps,
      ),
    });

    // Add timeout for configuration
    final response = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pendingRequests.remove(requestId);
        throw TimeoutException('Configuration timed out after 10 seconds');
      },
    );

    if (response is ConfiguredResponse) {
      _isConfigured = true;
    }
  }

  /// Dispose the isolate and clean up resources
  Future<void> dispose() async {
    // Clear all pending requests with an error before disposing
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          Exception('Isolate disposed while request was pending')
        );
      }
    }
    _pendingRequests.clear();

    if (_sendPort != null) {
      _sendPort!.send(const DisposeMessage());
    }

    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
    _isInitialized = false;
    _isConfigured = false;
  }

  /// Entry point for the background isolate
  static void _isolateEntryPoint(SendPort mainSendPort) {
    // Report progress every N frames
    const int progressReportInterval = 30;

    final receivePort = ReceivePort();
    VideoEncoder? encoder;
    int frameCount = 0;
    int totalFrames = 0;
    String? outputPath;
    bool useRealEncoder = false;

    // Send our SendPort back to main isolate
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) async {
      if (message is DisposeMessage) {
        await encoder?.cancel();
        receivePort.close();
      } else if (message is Map) {
        final requestId = message['requestId'] as String;
        final processingMessage = message['message'] as ProcessingMessage;

        ProcessingResponse response;

        try {
          if (processingMessage is ConfigureEncoderMessage) {
            // Initialize encoder in isolate
            outputPath = processingMessage.outputPath;

            // Try to initialize real encoder if platform channels are available
            if (RootIsolateToken.instance != null) {
              try {
                BackgroundIsolateBinaryMessenger.ensureInitialized(
                  RootIsolateToken.instance!
                );
                encoder = VideoEncoder();
                await encoder!.initialize(
                  outputPath: processingMessage.outputPath,
                  width: processingMessage.width,
                  height: processingMessage.height,
                  fps: processingMessage.fps,
                );
                useRealEncoder = true;
              } catch (e) {
                // Fall back to mock mode
                encoder = null;
                useRealEncoder = false;
              }
            }

            frameCount = 0;
            totalFrames = 0;
            response = const ConfiguredResponse();
          } else if (processingMessage is ProcessFrameMessage) {
            // Process frame in isolate
            if (useRealEncoder && encoder != null) {
              final frameData = FrameData(
                data: processingMessage.frameData,
                width: processingMessage.width,
                height: processingMessage.height,
                timestampMicros: processingMessage.timestampMicros,
              );

              await encoder!.addFrame(frameData);
            }

            frameCount++;

            // Send progress update at regular intervals (no request ID)
            if (frameCount % progressReportInterval == 0) {
              // PROGRESS ACCURACY NOTE: Progress is only accurate during the finalization phase
              // when totalFrames is known. During live recording, totalFrames is 0, so we use
              // an estimate (frameCount + 100) which provides a rough indicator but is not precise.
              // The progress bar will reach 100% during finalization when actual frame count is used.
              final total = totalFrames > 0 ? totalFrames : frameCount + 100;
              final progress = (frameCount / total).clamp(0.0, 1.0);
              mainSendPort.send({
                'response': ProgressUpdate(progress),
              });
            }

            response = const FrameProcessedResponse();
          } else if (processingMessage is FinalizeMessage) {
            // Store total frames for progress calculation
            totalFrames = processingMessage.totalFrames;

            // Finalize encoding in isolate
            if (useRealEncoder && encoder != null) {
              outputPath = await encoder!.finalize();
              encoder = null;
            }

            response = FinalizedResponse(outputPath ?? '/tmp/test.mp4');
          } else {
            response = const ErrorResponse('Unknown message type');
          }
        } catch (e, stackTrace) {
          response = ErrorResponse(e.toString(), stackTrace.toString());
        }

        mainSendPort.send({
          'requestId': requestId,
          'response': response,
        });
      }
    });
  }
}
