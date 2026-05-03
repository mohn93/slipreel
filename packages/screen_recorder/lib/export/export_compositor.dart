import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show Size;
import 'package:screen_recorder/export/frame_compositor.dart';

/// Per-frame compositor interface used by the export pipeline.
///
/// Two implementations exist:
///   * [InProcessExportCompositor] runs [FrameCompositor.compose]
///     inline on the calling isolate. Used by `flutter test` runs
///     because the test harness can't reliably attach a child
///     isolate to the engine for `Picture.toImage` rasterization.
///   * `IsolateFrameCompositor` (production default) hands compose
///     work off to a background isolate so the main isolate stays
///     free for decoder/encoder I/O.
abstract class ExportCompositor {
  /// Output canvas size — see [FrameCompositor.totalSize].
  Size get totalSize;

  /// Render one frame. Implementations must accept calls in
  /// monotonically increasing [position] order; controllers inside
  /// the underlying [FrameCompositor] (cursor smoother, focal tween)
  /// carry state across calls.
  Future<Uint8List> compose({
    required Uint8List bgra,
    required Duration position,
  });

  /// Release any background resources (isolate, ports, picture
  /// recorders). Idempotent — safe to call from a `finally` block.
  Future<void> dispose();
}

/// Adapter that wraps a [FrameCompositor] in the [ExportCompositor]
/// interface, so the export pipeline can pick between in-process
/// (test) and isolated (production) without branching the loop.
class InProcessExportCompositor implements ExportCompositor {
  InProcessExportCompositor(this._delegate);

  final FrameCompositor _delegate;

  @override
  Size get totalSize => _delegate.totalSize;

  @override
  Future<Uint8List> compose({
    required Uint8List bgra,
    required Duration position,
  }) =>
      _delegate.compose(videoFrameBgra: bgra, position: position);

  @override
  Future<void> dispose() async {
    // FrameCompositor doesn't own any teardownable resources of its
    // own — controllers are pure Dart, ui.Picture/Image are disposed
    // inside compose(). Nothing to do here.
  }
}
