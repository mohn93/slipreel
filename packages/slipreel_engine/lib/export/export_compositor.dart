import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show Size;
import 'package:slipreel_engine/export/frame_compositor.dart';

/// Per-frame compositor interface used by the export pipeline.
///
/// The sole implementation, [InProcessExportCompositor], runs
/// [FrameCompositor.compose] inline on the calling isolate. (An
/// isolate-based compositor was removed: `Picture.toImage` in a
/// background isolate crashes the Flutter engine on macOS.)
abstract class ExportCompositor {
  /// Output canvas size — see [FrameCompositor.totalSize].
  Size get totalSize;

  /// Actual pixel size of the buffers [compose] returns — see
  /// [FrameCompositor.renderSize]. Equals [totalSize] unless the
  /// compositor is downscale-rendering to the export resolution.
  Size get renderSize;

  /// Render one frame. Implementations must accept calls in
  /// monotonically increasing [position] order; controllers inside
  /// the underlying [FrameCompositor] (cursor smoother, focal tween)
  /// carry state across calls.
  Future<Uint8List> compose({
    required Uint8List bgra,
    required Duration position,
  });

  /// Advance the compositor's cross-frame state for [position] WITHOUT
  /// rendering. Used for source frames in trimmed-away gaps whose pixels
  /// ffmpeg drops: the pipeline feeds a blank placeholder instead, but the
  /// stateful controllers must still see the frame or every kept frame
  /// after the gap diverges. Same monotonic-order contract as [compose].
  void advance(Duration position);

  /// Release any background resources (isolate, ports, picture
  /// recorders). Idempotent — safe to call from a `finally` block.
  Future<void> dispose();
}

/// Optional capability for compositors whose state-only advancement must
/// await a forward-only side source (currently camera decode).
///
/// This is deliberately separate from [ExportCompositor]. Adding a concrete
/// method to that abstract class would still break every downstream class
/// using `implements ExportCompositor`, because Dart requires implementers to
/// provide all interface members even when the class supplies a body.
abstract interface class AsyncExportCompositorAdvance {
  Future<void> advanceAndWait(Duration position);
}

/// Advances [compositor] and awaits asynchronous side-source work when the
/// implementation advertises [AsyncExportCompositorAdvance]. Legacy
/// `implements ExportCompositor` classes keep using the original synchronous
/// [ExportCompositor.advance] contract unchanged.
Future<void> advanceExportCompositor(
  ExportCompositor compositor,
  Duration position,
) async {
  if (compositor case AsyncExportCompositorAdvance asyncCompositor) {
    await asyncCompositor.advanceAndWait(position);
  } else {
    compositor.advance(position);
  }
}

/// Adapter that wraps a [FrameCompositor] in the [ExportCompositor]
/// interface.
class InProcessExportCompositor
    implements ExportCompositor, AsyncExportCompositorAdvance {
  InProcessExportCompositor(this._delegate);

  final FrameCompositor _delegate;

  @override
  Size get totalSize => _delegate.totalSize;

  @override
  Size get renderSize => _delegate.renderSize;

  @override
  Future<Uint8List> compose({
    required Uint8List bgra,
    required Duration position,
  }) => _delegate.compose(videoFrameBgra: bgra, position: position);

  @override
  void advance(Duration position) => _delegate.advanceScenePass(position);

  @override
  Future<void> advanceAndWait(Duration position) =>
      _delegate.advanceWithoutCompose(position);

  @override
  Future<void> dispose() async {
    // m10: release the compositor's cached wallpaper ui.Image (rasterized once
    // and held for the whole export). Other resources are pure Dart or are
    // disposed inside compose().
    _delegate.dispose();
  }
}
