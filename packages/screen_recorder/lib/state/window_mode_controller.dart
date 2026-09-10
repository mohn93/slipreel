import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'window_mode.dart';

/// Single source of truth for the window's shape. Setting a mode updates
/// state and asks the native chrome to resize/restyle the window. Repeating
/// the current mode is a no-op so listeners and the native side aren't
/// churned needlessly.
class WindowModeController extends StateNotifier<WindowMode> {
  WindowModeController(this._chrome) : super(WindowMode.bar);

  final WindowChrome _chrome;
  int _panelHoldCount = 0;
  WindowMode? _modeBeforePanelHold;
  WindowMode? _deferredMode;

  Future<void> _set(WindowMode mode) async {
    // A blocking modal owns the full-size panel until it is dismissed. Keep
    // track of mode changes requested underneath it (for example the bar's
    // first-frame showBar call or a recording status change), but do not let
    // them collapse the native window around visible dialog content.
    if (_panelHoldCount > 0) {
      _deferredMode = mode;
      return;
    }
    await _apply(mode);
  }

  Future<void> _apply(WindowMode mode) async {
    if (state == mode) return;
    state = mode;
    await _chrome.setMode(mode);
  }

  /// Keeps the native window in panel mode while a blocking modal route is
  /// visible. Nested modals share the hold and the latest mode requested
  /// underneath them is applied after the final modal closes.
  WindowPanelHold holdPanelForModal() {
    final Future<void> ready;
    if (_panelHoldCount == 0) {
      _modeBeforePanelHold = state;
      _deferredMode = null;
      _panelHoldCount = 1;
      ready = _apply(WindowMode.panel);
    } else {
      _panelHoldCount++;
      ready = Future<void>.value();
    }
    return WindowPanelHold._(this, ready);
  }

  Future<void> _releasePanelHold() async {
    if (_panelHoldCount == 0) return;
    _panelHoldCount--;
    if (_panelHoldCount > 0) return;

    final target = _deferredMode ?? _modeBeforePanelHold ?? WindowMode.bar;
    _modeBeforePanelHold = null;
    _deferredMode = null;
    await _apply(target);
  }

  Future<void> showBar() => _set(WindowMode.bar);
  Future<void> showPill() => _set(WindowMode.pill);
  Future<void> showPanel() => _set(WindowMode.panel);
}

/// A single, idempotently releasable claim on panel mode for modal UI.
class WindowPanelHold {
  WindowPanelHold._(this._controller, this.ready);

  final WindowModeController _controller;
  final Future<void> ready;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await ready;
    } finally {
      await _controller._releasePanelHold();
    }
  }
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
