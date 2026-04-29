import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/source_picker/concurrent_loader.dart';

void main() {
  test('never exceeds maxInFlight, all complete', () async {
    final loader = ConcurrentLoader<int>(maxInFlight: 4);
    int inFlight = 0;
    int peak = 0;
    final completers = <Completer<int>>[];

    Future<int> task(int i) async {
      inFlight++;
      peak = inFlight > peak ? inFlight : peak;
      final c = Completer<int>();
      completers.add(c);
      final value = await c.future;
      inFlight--;
      return value;
    }

    final futures = List.generate(10, (i) => loader.run(() => task(i)));

    await Future<void>.delayed(Duration.zero);
    expect(peak, lessThanOrEqualTo(4));

    for (var i = 0; i < completers.length; i++) {
      expect(inFlight, lessThanOrEqualTo(4));
      completers[i].complete(i);
      await Future<void>.delayed(Duration.zero);
    }

    final results = await Future.wait(futures);
    expect(results, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(peak, lessThanOrEqualTo(4));
  });

  test('forwards errors to caller', () async {
    final loader = ConcurrentLoader<int>(maxInFlight: 1);
    expect(
      loader.run<int>(() async => throw StateError('boom')),
      throwsA(isA<StateError>()),
    );
  });
}
