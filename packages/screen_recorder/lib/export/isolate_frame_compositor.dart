import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:screen_recorder/export/export_compositor.dart';
import 'package:screen_recorder/export/frame_compositor.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
import 'package:screen_recorder/state/editor_project_state.dart';
import 'package:screen_recorder/utils/app_logger.dart';

/// Background-isolate wrapper around [FrameCompositor].
///
/// Owns a long-lived isolate that holds one `FrameCompositor` instance.
/// Frames flow main → isolate → main as `TransferableTypedData` so the
/// per-frame BGRA / RGBA buffers move zero-copy between isolates
/// instead of being deep-cloned.
///
/// Why: Flutter's `Picture.toImage().toByteData()` does CPU-bound
/// work; running it on the main isolate stalls the decoder/encoder
/// pumps and bottlenecks the export. Off-main, the compose pipeline
/// runs concurrently with decode and encode I/O on the main isolate,
/// reclaiming most of the throughput we lost when the bare cursor
/// blit was replaced with the full preview-matching compositor.
class IsolateFrameCompositor implements ExportCompositor {
  IsolateFrameCompositor._({
    required this.totalSize,
    required Isolate isolate,
    required SendPort controlPort,
    required ReceivePort responsePort,
    required ReceivePort exitPort,
  })  : _isolate = isolate,
        _controlPort = controlPort,
        _responsePort = responsePort,
        _exitPort = exitPort {
    _responsePort.listen(_handleResponse);
    _exitPort.listen(_handleExit);
  }

  /// Output canvas size — same as [FrameCompositor.totalSize].
  @override
  final Size totalSize;

  final Isolate _isolate;
  final SendPort _controlPort;
  final ReceivePort _responsePort;
  final ReceivePort _exitPort;

  final Map<int, Completer<Uint8List>> _pending = {};
  int _nextRequestId = 0;
  bool _disposed = false;

  /// Spawn the compositor isolate. The returned future completes once
  /// the isolate has constructed its `FrameCompositor` and reported
  /// the resolved [totalSize].
  static Future<IsolateFrameCompositor> spawn({
    required EditorProjectState projectState,
    required CursorRecording cursorRecording,
    required RecordingMetadata? metadata,
    required Size videoSize,
    required int fps,
  }) async {
    final token = RootIsolateToken.instance;
    if (token == null) {
      throw StateError(
          'IsolateFrameCompositor requires a RootIsolateToken — call from '
          'a Flutter isolate (UI thread), not a pure Dart entry point.');
    }
    final initPort = ReceivePort();
    final exitPort = ReceivePort();
    final isolate = await Isolate.spawn<_Bootstrap>(
      _entry,
      _Bootstrap(
        token: token,
        replyPort: initPort.sendPort,
        projectState: projectState,
        cursorRecording: cursorRecording,
        metadata: metadata,
        videoSize: videoSize,
        fps: fps,
      ),
      onExit: exitPort.sendPort,
      errorsAreFatal: false,
    );
    final ready = await initPort.first as _Ready;
    initPort.close();

    final responsePort = ReceivePort();
    ready.controlPort.send(_SetResponsePort(responsePort.sendPort));

    return IsolateFrameCompositor._(
      totalSize: ready.totalSize,
      isolate: isolate,
      controlPort: ready.controlPort,
      responsePort: responsePort,
      exitPort: exitPort,
    );
  }

  /// Submit one frame for compositing. Resolves with the rendered RGBA
  /// bytes at [totalSize]. Throws [StateError] if the compositor has
  /// already been disposed or if its isolate died with the request
  /// still in flight.
  @override
  Future<Uint8List> compose({
    required Uint8List bgra,
    required Duration position,
  }) {
    if (_disposed) {
      return Future.error(
          StateError('IsolateFrameCompositor.compose after dispose()'));
    }
    final id = _nextRequestId++;
    final completer = Completer<Uint8List>();
    _pending[id] = completer;
    _controlPort.send(_ComposeRequest(
      id: id,
      bgra: TransferableTypedData.fromList([bgra]),
      positionMicros: position.inMicroseconds,
    ));
    return completer.future;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _controlPort.send(const _Shutdown());
    } catch (_) {
      // SendPort already closed if isolate exited — ignore.
    }
    _isolate.kill(priority: Isolate.immediate);
    _responsePort.close();
    _exitPort.close();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(
            StateError('IsolateFrameCompositor disposed mid-flight'));
      }
    }
    _pending.clear();
  }

  void _handleResponse(dynamic msg) {
    if (msg is! _ComposeResponse) return;
    final completer = _pending.remove(msg.id);
    if (completer == null) return;
    if (msg.errorMessage != null) {
      completer.completeError(StateError(
          'Compositor isolate failed on frame ${msg.id}: ${msg.errorMessage}'));
      return;
    }
    final rgba = msg.rgba;
    if (rgba == null) {
      completer.completeError(
          StateError('Compositor isolate returned no payload for ${msg.id}'));
      return;
    }
    completer.complete(rgba.materialize().asUint8List());
  }

  void _handleExit(dynamic _) {
    if (_disposed) return;
    AppLogger.ffmpeg.w('Compositor isolate exited unexpectedly');
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('Compositor isolate exited mid-flight'));
      }
    }
    _pending.clear();
  }
}

// --- isolate-side -----------------------------------------------------------

class _Bootstrap {
  const _Bootstrap({
    required this.token,
    required this.replyPort,
    required this.projectState,
    required this.cursorRecording,
    required this.metadata,
    required this.videoSize,
    required this.fps,
  });

  final RootIsolateToken token;
  final SendPort replyPort;
  final EditorProjectState projectState;
  final CursorRecording cursorRecording;
  final RecordingMetadata? metadata;
  final Size videoSize;
  final int fps;
}

class _Ready {
  const _Ready({required this.controlPort, required this.totalSize});
  final SendPort controlPort;
  final Size totalSize;
}

class _SetResponsePort {
  const _SetResponsePort(this.port);
  final SendPort port;
}

class _ComposeRequest {
  const _ComposeRequest({
    required this.id,
    required this.bgra,
    required this.positionMicros,
  });
  final int id;
  final TransferableTypedData bgra;
  final int positionMicros;
}

class _ComposeResponse {
  const _ComposeResponse({
    required this.id,
    this.rgba,
    this.errorMessage,
  });
  final int id;
  final TransferableTypedData? rgba;
  final String? errorMessage;
}

class _Shutdown {
  const _Shutdown();
}

Future<void> _entry(_Bootstrap b) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(b.token);
  final compositor = FrameCompositor(
    projectState: b.projectState,
    cursorRecording: b.cursorRecording,
    metadata: b.metadata,
    videoSize: b.videoSize,
    fps: b.fps,
  );

  final controlPort = ReceivePort();
  b.replyPort.send(_Ready(
    controlPort: controlPort.sendPort,
    totalSize: compositor.totalSize,
  ));

  SendPort? responsePort;
  await for (final msg in controlPort) {
    if (msg is _SetResponsePort) {
      responsePort = msg.port;
      continue;
    }
    if (msg is _Shutdown) {
      break;
    }
    if (msg is _ComposeRequest) {
      final port = responsePort;
      if (port == null) continue; // ignore until handshake completes
      try {
        final bgra = msg.bgra.materialize().asUint8List();
        final rgba = await compositor.compose(
          videoFrameBgra: bgra,
          position: Duration(microseconds: msg.positionMicros),
        );
        port.send(_ComposeResponse(
          id: msg.id,
          rgba: TransferableTypedData.fromList([rgba]),
        ));
      } catch (e, s) {
        port.send(_ComposeResponse(
          id: msg.id,
          errorMessage: '$e\n$s',
        ));
      }
    }
  }
  controlPort.close();
}
