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

  bool get isInitialized => _isInitialized;

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
      } else if (message is ErrorResponse) {
        completer.completeError(Exception(message.message));
      }
    });

    await completer.future;
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
  }

  /// Entry point for the background isolate
  static void _isolateEntryPoint(SendPort mainSendPort) {
    final receivePort = ReceivePort();

    // Send our SendPort back to main isolate
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) {
      if (message is DisposeMessage) {
        receivePort.close();
      }
    });
  }
}
