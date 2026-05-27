import 'dart:async';

/// Thrown by an export pipeline's `run()` when its [CancelToken] was
/// cancelled. Lets callers distinguish a user-cancel from a real failure.
class ExportCancelledException implements Exception {
  const ExportCancelledException();
  @override
  String toString() => 'ExportCancelledException: export was cancelled';
}

/// Cooperative cancellation signal passed into an export pipeline.
class CancelToken {
  final Completer<void> _completer = Completer<void>();

  /// Whether [cancel] has been called.
  bool get isCancelled => _completer.isCompleted;

  /// Completes when [cancel] is called. Used to interrupt blocked stages.
  Future<void> get whenCancelled => _completer.future;

  /// Requests cancellation. Idempotent.
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}
