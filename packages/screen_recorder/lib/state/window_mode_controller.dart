import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'window_mode.dart';

/// Single source of truth for the window's shape. Setting a mode updates
/// state and asks the native chrome to resize/restyle the window. Repeating
/// the current mode is a no-op so listeners and the native side aren't
/// churned needlessly.
class WindowModeController extends StateNotifier<WindowMode> {
  WindowModeController(this._chrome) : super(WindowMode.bar);

  final WindowChrome _chrome;

  Future<void> _set(WindowMode mode) async {
    if (state == mode) return;
    state = mode;
    await _chrome.setMode(mode);
  }

  Future<void> showBar() => _set(WindowMode.bar);
  Future<void> showPill() => _set(WindowMode.pill);
  Future<void> showPanel() => _set(WindowMode.panel);
}

/// Overridden in `main.dart` with a real [WindowChrome]. The default throws
/// so a missing override is caught immediately rather than silently no-op.
final windowChromeProvider = Provider<WindowChrome>((ref) {
  throw UnimplementedError('windowChromeProvider must be overridden in main()');
});

final windowModeControllerProvider =
    StateNotifierProvider<WindowModeController, WindowMode>(
  (ref) => WindowModeController(ref.watch(windowChromeProvider)),
);
