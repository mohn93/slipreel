import 'dart:async';
import 'dart:collection';

/// Runs async tasks with a global maximum-in-flight cap. Tasks queue FIFO and
/// start as slots free up.
class ConcurrentLoader<T> {
  ConcurrentLoader({required this.maxInFlight}) : assert(maxInFlight > 0);

  final int maxInFlight;
  int _inFlight = 0;
  final Queue<_Pending<T>> _queue = Queue();

  Future<R> run<R>(Future<R> Function() task) {
    final completer = Completer<R>();
    _queue.add(_Pending<T>(() async {
      try {
        final result = await task();
        completer.complete(result as R);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }));
    _drain();
    return completer.future;
  }

  void _drain() {
    while (_inFlight < maxInFlight && _queue.isNotEmpty) {
      final pending = _queue.removeFirst();
      _inFlight++;
      pending.run().whenComplete(() {
        _inFlight--;
        _drain();
      });
    }
  }
}

class _Pending<T> {
  _Pending(this.run);
  final Future<void> Function() run;
}
