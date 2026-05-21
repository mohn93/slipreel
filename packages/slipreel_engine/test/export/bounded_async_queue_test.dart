import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/bounded_async_queue.dart';

void main() {
  group('BoundedAsyncQueue', () {
    test('FIFO order is preserved', () async {
      final q = BoundedAsyncQueue<int>(4);
      await q.add(1);
      await q.add(2);
      await q.add(3);
      expect(await q.take(), 1);
      expect(await q.take(), 2);
      expect(await q.take(), 3);
    });

    test('add suspends when buffer is full and resumes after take', () async {
      final q = BoundedAsyncQueue<int>(2);
      await q.add(1);
      await q.add(2);

      var addCompleted = false;
      final pendingAdd = q.add(3).then((_) => addCompleted = true);

      // Yield control so add() can attempt and discover the buffer is full.
      await Future<void>.delayed(Duration.zero);
      expect(addCompleted, isFalse, reason: 'add must block while at capacity');

      expect(await q.take(), 1);
      await pendingAdd;
      expect(addCompleted, isTrue);
      expect(q.length, 2);
    });

    test('take suspends when empty and resumes when item arrives', () async {
      final q = BoundedAsyncQueue<int>(2);

      final pending = q.take();
      var resolved = false;
      pending.then((_) => resolved = true);

      await Future<void>.delayed(Duration.zero);
      expect(resolved, isFalse);

      await q.add(42);
      expect(await pending, 42);
    });

    test('close drains pending items, then returns null', () async {
      final q = BoundedAsyncQueue<int>(4);
      await q.add(1);
      await q.add(2);
      q.close();
      expect(await q.take(), 1);
      expect(await q.take(), 2);
      expect(await q.take(), isNull);
    });

    test('close wakes a take waiter with null', () async {
      final q = BoundedAsyncQueue<int>(2);
      final pending = q.take();
      q.close();
      expect(await pending, isNull);
    });

    test('add after close throws', () async {
      final q = BoundedAsyncQueue<int>(2);
      q.close();
      expect(() => q.add(1), throwsStateError);
    });

    test('close while add is blocked surfaces StateError on that add', () async {
      final q = BoundedAsyncQueue<int>(1);
      await q.add(1);
      final pending = q.add(2);
      // Don't await — close it while the add is parked at full capacity.
      q.close();
      await expectLater(pending, throwsStateError);
    });

    test('producer/consumer streaming: 50 items pass through a depth-2 queue',
        () async {
      final q = BoundedAsyncQueue<int>(2);
      final received = <int>[];

      final producer = () async {
        for (var i = 0; i < 50; i++) {
          await q.add(i);
        }
        q.close();
      }();

      final consumer = () async {
        while (true) {
          final v = await q.take();
          if (v == null) break;
          received.add(v);
        }
      }();

      await Future.wait([producer, consumer]);
      expect(received, List.generate(50, (i) => i));
    });
  });
}
