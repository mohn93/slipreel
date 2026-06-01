import 'package:flutter/material.dart';

/// Type of alert. Drives the icon, accent color, and default duration.
enum AlertType {
  success,
  error,
  warning,
  info;

  IconData get icon => switch (this) {
        AlertType.success => Icons.check_circle_rounded,
        AlertType.error => Icons.error_rounded,
        AlertType.warning => Icons.warning_amber_rounded,
        AlertType.info => Icons.info_rounded,
      };

  Color get accent => switch (this) {
        AlertType.success => const Color(0xFF34C759),
        AlertType.error => const Color(0xFFFF453A),
        AlertType.warning => const Color(0xFFFF9F0A),
        AlertType.info => const Color(0xFF0A84FF),
      };

  Duration get defaultDuration => switch (this) {
        AlertType.success || AlertType.info => const Duration(seconds: 4),
        AlertType.error || AlertType.warning => const Duration(seconds: 6),
      };
}

/// Optional action button shown on the right side of an alert.
class AppAlertAction {
  const AppAlertAction({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
}

/// One live entry in the alert stack. Identity is by [key] so the
/// widget tree can match entries across rebuilds even if message text
/// or action are equal.
class AlertEntry {
  AlertEntry({
    required this.type,
    required this.message,
    required this.duration,
    this.action,
  }) : key = UniqueKey();

  final AlertType type;
  final String message;
  final Duration duration;
  final AppAlertAction? action;
  final Key key;
}
