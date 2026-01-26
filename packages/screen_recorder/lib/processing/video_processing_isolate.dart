import 'dart:async';
import 'dart:isolate';

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
        final requestId = message['requestId'] as String;
        final response = message['response'] as ProcessingResponse;

        final pending = _pendingRequests.remove(requestId);
        if (pending != null && !pending.isCompleted) {
          if (response is ErrorResponse) {
            pending.completeError(Exception(response.message));
          } else {
            pending.complete(response);
          }
        }
      } else if (message is ErrorResponse) {
        completer.completeError(Exception(message.message));
      }
    });

    await completer.future;
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

    final response = await completer.future;
    if (response is ConfiguredResponse) {
      _isConfigured = true;
    }
  }

  /// Dispose the isolate and clean up resources
  Future<void> dispose() async {
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
    _pendingRequests.clear();
  }

  /// Entry point for the background isolate
  static void _isolateEntryPoint(SendPort mainSendPort) {
    final receivePort = ReceivePort();

    // Send our SendPort back to main isolate
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) {
      if (message is DisposeMessage) {
        receivePort.close();
      } else if (message is Map) {
        final requestId = message['requestId'] as String;
        final processingMessage = message['message'] as ProcessingMessage;

        ProcessingResponse response;

        if (processingMessage is ConfigureEncoderMessage) {
          // TODO: Actually initialize encoder in isolate
          response = const ConfiguredResponse();
        } else {
          response = const ErrorResponse('Unknown message type');
        }

        mainSendPort.send({
          'requestId': requestId,
          'response': response,
        });
      }
    });
  }
}
