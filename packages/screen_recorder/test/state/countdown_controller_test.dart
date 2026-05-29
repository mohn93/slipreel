import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/countdown_controller.dart';

void main() {
  test('initial state is inactive with remaining 0', () {
    final c = CountdownController();
    expect(c.state.active, isFalse);
    expect(c.state.remaining, 0);
  });

  test('run(3) ticks down each second; fires onComplete at 0', () {
    fakeAsync((async) {
      final c = CountdownController();
      int completed = 0;
      c.run(seconds: 3, onComplete: () => completed++);
      expect(c.state.remaining, 3);
      expect(c.state.active, isTrue);
      async.elapse(const Duration(seconds: 1));
      expect(c.state.remaining, 2);
      async.elapse(const Duration(seconds: 1));
      expect(c.state.remaining, 1);
      async.elapse(const Duration(seconds: 1));
      expect(c.state.remaining, 0);
      expect(c.state.active, isFalse);
      expect(completed, 1);
    });
  });

  test('cancel mid-flight stops the timer; onComplete does NOT fire', () {
    fakeAsync((async) {
      final c = CountdownController();
      int completed = 0;
      c.run(seconds: 3, onComplete: () => completed++);
      async.elapse(const Duration(seconds: 1));
      c.cancel();
      async.elapse(const Duration(seconds: 5));
      expect(c.state.active, isFalse);
      expect(completed, 0);
    });
  });

  test('run(0) fires onComplete immediately', () {
    fakeAsync((async) {
      final c = CountdownController();
      int completed = 0;
      c.run(seconds: 0, onComplete: () => completed++);
      async.flushMicrotasks();
      expect(completed, 1);
      expect(c.state.active, isFalse);
    });
  });

  test('run while already active is a no-op', () {
    fakeAsync((async) {
      final c = CountdownController();
      int firstCompleted = 0;
      int secondCompleted = 0;
      c.run(seconds: 3, onComplete: () => firstCompleted++);
      c.run(seconds: 5, onComplete: () => secondCompleted++);
      async.elapse(const Duration(seconds: 3));
      expect(firstCompleted, 1);
      expect(secondCompleted, 0);
      expect(c.state.active, isFalse);
    });
  });
}
