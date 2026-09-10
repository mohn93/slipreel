import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

import '../../state/window_mode_controller.dart';

/// Prevents full-size modal UI from being laid out inside the recording bar
/// or recording pill. A dimming barrier distinguishes blocking modal surfaces
/// (dialogs and modal sheets) from compact popup menus.
class PanelModalRouteObserver extends NavigatorObserver {
  PanelModalRouteObserver(this._window);

  final WindowModeController _window;
  final Map<Route<dynamic>, WindowPanelHold> _holds = {};

  bool _needsPanel(Route<dynamic> route) =>
      route is PopupRoute<dynamic> && route.barrierColor != null;

  void _hold(Route<dynamic>? route) {
    if (route == null || !_needsPanel(route) || _holds.containsKey(route)) {
      return;
    }
    final hold = _window.holdPanelForModal();
    _holds[route] = hold;
    unawaited(_guard(hold.ready, 'expand window for modal'));
  }

  void _release(Route<dynamic>? route) {
    if (route == null) return;
    final hold = _holds.remove(route);
    if (hold != null) {
      unawaited(_guard(hold.release(), 'restore window after modal'));
    }
  }

  Future<void> _guard(Future<void> operation, String action) async {
    try {
      await operation;
    } catch (error, stackTrace) {
      AppLogger.platform.w(
        'Failed to $action',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _hold(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _release(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _release(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _release(oldRoute);
    _hold(newRoute);
  }
}
