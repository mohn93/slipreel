// packages/slipreel_engine/lib/models/output_aspect.dart

/// Output canvas aspect ratio. Picked from the editor's canvas toolbar
/// and persisted on `EditorProjectState`. Drives canvas dimensions in
/// both the live preview (PlaybackCanvas) and the export pipeline
/// (FrameCompositor) via `OutputCanvasResolver`.
///
/// `auto` defers to the source video's intrinsic aspect ratio.
/// Explicit variants force the canvas to the named width:height ratio;
/// the video is letterbox-fit centered inside, with the WindowFrame's
/// wallpaper filling any extra space.
enum OutputAspect {
  auto,
  wide16x9,
  square1x1,
  classic4x3,
  vertical9x16,
  tall3x4,
  portrait4x5;

  /// Numeric width/height ratio. `null` for [auto] — callers resolve
  /// against the source video size at render time.
  double? get ratio {
    switch (this) {
      case OutputAspect.auto:
        return null;
      case OutputAspect.wide16x9:
        return 16 / 9;
      case OutputAspect.square1x1:
        return 1.0;
      case OutputAspect.classic4x3:
        return 4 / 3;
      case OutputAspect.vertical9x16:
        return 9 / 16;
      case OutputAspect.tall3x4:
        return 3 / 4;
      case OutputAspect.portrait4x5:
        return 4 / 5;
    }
  }

  /// Human-readable label shown in the editor's aspect picker.
  String get label {
    switch (this) {
      case OutputAspect.auto:
        return 'Auto';
      case OutputAspect.wide16x9:
        return 'Wide 16:9';
      case OutputAspect.square1x1:
        return 'Square 1:1';
      case OutputAspect.classic4x3:
        return 'Classic 4:3';
      case OutputAspect.vertical9x16:
        return 'Vertical 9:16';
      case OutputAspect.tall3x4:
        return 'Tall 3:4';
      case OutputAspect.portrait4x5:
        return 'Portrait 4:5';
    }
  }
}
