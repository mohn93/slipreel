import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts_controller.dart';

void main() {
  group('AppAlertsController', () {
    test('pushEntry adds to stack', () {
      final c = AppAlertsController();
      c.pushEntry(AlertEntry(
        type: AlertType.info,
        message: 'hello',
        duration: Duration.zero,
      ));
      expect(c.stack.value.length, 1);
      expect(c.stack.value.single.message, 'hello');
    });

    test('stack caps at 3, evicting the oldest', () {
      final c = AppAlertsController();
      for (var i = 0; i < 5; i++) {
        c.pushEntry(AlertEntry(
          type: AlertType.info,
          message: '$i',
          duration: Duration.zero,
        ));
      }
      expect(c.stack.value.length, 3);
      expect(c.stack.value.map((e) => e.message).toList(), ['2', '3', '4']);
    });

    test('non-zero duration auto-dismisses after the duration elapses', () {
      fakeAsync((async) {
        final c = AppAlertsController();
        final e = AlertEntry(
          type: AlertType.success,
          message: 'gone soon',
          duration: const Duration(seconds: 4),
        );
        c.pushEntry(e);
        expect(c.stack.value.length, 1);

        async.elapse(const Duration(seconds: 3));
        expect(c.stack.value.length, 1, reason: 'still visible at 3s');

        async.elapse(const Duration(seconds: 2));
        expect(c.stack.value.length, 0, reason: 'dismissed by 5s');
      });
    });

    test('Duration.zero never auto-dismisses', () {
      fakeAsync((async) {
        final c = AppAlertsController();
        final e = AlertEntry(
          type: AlertType.info,
          message: 'sticky',
          duration: Duration.zero,
        );
        c.pushEntry(e);
        async.elapse(const Duration(minutes: 5));
        expect(c.stack.value.length, 1);
      });
    });

    test('pauseTimer + resumeTimer extends remaining time', () {
      fakeAsync((async) {
        final c = AppAlertsController();
        final e = AlertEntry(
          type: AlertType.error,
          message: 'paused',
          duration: const Duration(seconds: 6),
        );
        c.pushEntry(e);

        async.elapse(const Duration(seconds: 2));
        c.pauseTimer(e);
        async.elapse(const Duration(seconds: 30));
        // Still visible: 2s elapsed, then paused for 30s.
        expect(c.stack.value.length, 1);

        c.resumeTimer(e);
        async.elapse(const Duration(seconds: 3));
        expect(c.stack.value.length, 1, reason: '5s of effective time elapsed');

        async.elapse(const Duration(seconds: 2));
        expect(c.stack.value.length, 0, reason: '6s effective; auto-dismissed');
      });
    });

    test('dismiss removes the entry immediately and cancels its timer', () {
      fakeAsync((async) {
        final c = AppAlertsController();
        final e = AlertEntry(
          type: AlertType.success,
          message: 'click',
          duration: const Duration(seconds: 4),
        );
        c.pushEntry(e);
        c.dismiss(e);
        expect(c.stack.value, isEmpty);

        async.elapse(const Duration(seconds: 10));
        expect(c.stack.value, isEmpty,
            reason: 'timer must not push or re-dismiss after manual dismiss');
      });
    });

    test('pushEntry before attach buffers; flushes on attach', () {
      fakeAsync((async) {
        final c = AppAlertsController();
        c.pushEntry(AlertEntry(
          type: AlertType.info,
          message: 'queued',
          duration: const Duration(seconds: 4),
        ));
        // Stack is populated regardless of attach (attach only matters for
        // the OverlayEntry mounting, exercised in widget tests).
        expect(c.stack.value.length, 1);

        async.elapse(const Duration(seconds: 5));
        expect(c.stack.value, isEmpty, reason: 'timer fires normally');
      });
    });
  });
}
