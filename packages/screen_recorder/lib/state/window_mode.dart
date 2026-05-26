// packages/screen_recorder/lib/state/window_mode.dart

/// The three shapes the single app window can take.
enum WindowMode {
  /// Small, borderless, always-on-top, draggable bar (default / idle).
  bar,

  /// Tiny borderless pill shown while recording.
  pill,

  /// Normal resizable window for Recents / Settings / the editor.
  panel,
}

/// Seam over the native window-morphing channel so the controller is
/// unit-testable without a live method channel.
abstract class WindowChrome {
  Future<void> setMode(WindowMode mode);

  /// Pops up the native gear menu and resolves to the chosen action id
  /// ('recents' | 'settings' | 'quit') or null if dismissed.
  Future<String?> showGearMenu();

  /// Begins a native window drag from the current mouse event, so the user can
  /// reposition the borderless bar by dragging any non-button area.
  Future<void> startWindowDrag();

  /// Resizes the floating bar window to [width]×[height] points, keeping its
  /// top-left corner fixed (grows/shrinks on the right & bottom). Native no-ops
  /// unless in bar mode. Hugs the bar's variable content (mic label, meter row).
  Future<void> setBarSize(double width, double height);
}
