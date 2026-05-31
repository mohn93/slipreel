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
  double? get ratio => switch (this) {
        OutputAspect.auto => null,
        OutputAspect.wide16x9 => 16 / 9,
        OutputAspect.square1x1 => 1.0,
        OutputAspect.classic4x3 => 4 / 3,
        OutputAspect.vertical9x16 => 9 / 16,
        OutputAspect.tall3x4 => 3 / 4,
        OutputAspect.portrait4x5 => 4 / 5,
      };

  /// Human-readable label shown in the editor's aspect picker.
  String get label => switch (this) {
        OutputAspect.auto => 'Auto',
        OutputAspect.wide16x9 => 'Wide 16:9',
        OutputAspect.square1x1 => 'Square 1:1',
        OutputAspect.classic4x3 => 'Classic 4:3',
        OutputAspect.vertical9x16 => 'Vertical 9:16',
        OutputAspect.tall3x4 => 'Tall 3:4',
        OutputAspect.portrait4x5 => 'Portrait 4:5',
      };
}
