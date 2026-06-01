import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';

void main() {
  group('AlertType', () {
    test('default durations match spec', () {
      expect(AlertType.success.defaultDuration, const Duration(seconds: 4));
      expect(AlertType.info.defaultDuration, const Duration(seconds: 4));
      expect(AlertType.error.defaultDuration, const Duration(seconds: 6));
      expect(AlertType.warning.defaultDuration, const Duration(seconds: 6));
    });

    test('accent colors match spec', () {
      expect(AlertType.success.accent, const Color(0xFF34C759));
      expect(AlertType.error.accent, const Color(0xFFFF453A));
      expect(AlertType.warning.accent, const Color(0xFFFF9F0A));
      expect(AlertType.info.accent, const Color(0xFF0A84FF));
    });

    test('icons map to the spec set', () {
      expect(AlertType.success.icon, Icons.check_circle_rounded);
      expect(AlertType.error.icon, Icons.error_rounded);
      expect(AlertType.warning.icon, Icons.warning_amber_rounded);
      expect(AlertType.info.icon, Icons.info_rounded);
    });
  });

  group('AppAlertAction', () {
    test('stores label and callback', () {
      var fired = 0;
      final a = AppAlertAction(label: 'Retry', onPressed: () => fired++);
      expect(a.label, 'Retry');
      a.onPressed();
      expect(fired, 1);
    });
  });
}
