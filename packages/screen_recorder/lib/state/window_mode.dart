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
}
