import 'package:flutter/widgets.dart';

import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts_controller.dart';

/// BuildContext-free static API for firing top-of-window alerts.
///
/// All four methods enqueue the alert into the shared
/// [AppAlertsController.instance]. The controller's [OverlayEntry] is
/// installed once at app start (see `main.dart` → [attach]); calls
/// made before that still land on the stack and become visible as
/// soon as the overlay is mounted.
class AppAlerts {
  AppAlerts._();

  /// Wires the controller into the app's root [Overlay]. Called once
  /// from `main.dart` inside a post-frame callback. Idempotent across
  /// hot-restart.
  static void attach(OverlayState overlay, WidgetBuilder builder) =>
      AppAlertsController.instance.attach(overlay, builder);

  static void success(String message,
          {AppAlertAction? action, Duration? duration}) =>
      _push(AlertType.success, message, action, duration);

  static void error(String message,
          {AppAlertAction? action, Duration? duration}) =>
      _push(AlertType.error, message, action, duration);

  static void warning(String message,
          {AppAlertAction? action, Duration? duration}) =>
      _push(AlertType.warning, message, action, duration);

  static void info(String message,
          {AppAlertAction? action, Duration? duration}) =>
      _push(AlertType.info, message, action, duration);

  static void _push(AlertType type, String message,
      AppAlertAction? action, Duration? duration) {
    AppAlertsController.instance.pushEntry(AlertEntry(
      type: type,
      message: message,
      duration: duration ?? type.defaultDuration,
      action: action,
    ));
  }
}
