import 'dart:async';

/// Single-producer / single-consumer async FIFO with a fixed capacity.
///
/// Used to chain stages of the export pipeline (decode → compose → encode)
/// so each stage can run concurrently. The bound matters: composed RGBA
/// frames are ~10MB at 1440p, so an unbounded queue would balloon if the
/// encoder ever falls behind the compositor.
///
/// `add` suspends when the buffer is full; `take` suspends when it's empty.
/// `close` wakes any pending waiters; further `add`s throw, `take`s drain
/// then return null. Designed for one writer and one reader — multiple
/// concurrent producers or consumers will deadlock-or-misorder because
/// the implementation only tracks a single waiter on each side.
class BoundedAsyncQueue<T> {
  BoundedAsyncQueue(this.capacity) : assert(capacity > 0);

  final int capacity;
  final List<T> _buffer = [];
  Completer<void>? _spaceAvailable;
  Completer<void>? _itemAvailable;
  bool _closed = false;

  bool get isClosed => _closed;
  int get length => _buffer.length;

  Future<void> add(T item) async {
    while (_buffer.length >= capacity && !_closed) {
      _spaceAvailable ??= Completer<void>();
      await _spaceAvailable!.future;
    }
    if (_closed) {
      throw StateError('BoundedAsyncQueue.add after close');
    }
    _buffer.add(item);
    final w = _itemAvailable;
    _itemAvailable = null;
    w?.complete();
  }

  Future<T?> take() async {
    while (_buffer.isEmpty && !_closed) {
      _itemAvailable ??= Completer<void>();
      await _itemAvailable!.future;
    }
    if (_buffer.isEmpty) return null;
    final item = _buffer.removeAt(0);
    final w = _spaceAvailable;
    _spaceAvailable = null;
    w?.complete();
    return item;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    // Wake both sides so blocked add/take re-check _closed and exit.
    _itemAvailable?.complete();
    _itemAvailable = null;
    _spaceAvailable?.complete();
    _spaceAvailable = null;
  }
}
