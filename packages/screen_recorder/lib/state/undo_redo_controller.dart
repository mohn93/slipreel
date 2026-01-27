/// A generic controller for managing undo/redo state history.
///
/// Maintains two stacks: one for undo history and one for redo history.
/// When a new state is pushed after an undo operation, the redo stack is cleared.
/// Enforces a maximum stack size to prevent memory issues.
class UndoRedoController<T> {
  /// The maximum number of states to keep in the undo stack.
  final int maxSize;

  /// Stack of previous states for undo operations.
  /// The last item is the current state.
  final List<T> _undoStack = [];

  /// Stack of states that were undone and can be redone.
  final List<T> _redoStack = [];

  /// Creates an undo/redo controller with optional max stack size.
  ///
  /// [maxSize] defaults to 50 states.
  UndoRedoController({this.maxSize = 50});

  /// Returns true if there are states to undo.
  ///
  /// Can undo when there are at least 2 states in the undo stack
  /// (current state + at least one previous state).
  bool get canUndo => _undoStack.length > 1;

  /// Returns true if there are states to redo.
  bool get canRedo => _redoStack.isNotEmpty;

  /// Pushes a new state onto the undo stack.
  ///
  /// Clears the redo stack since we're creating a new timeline.
  /// Enforces max stack size by removing oldest states if needed.
  void push(T state) {
    _undoStack.add(state);
    _redoStack.clear();

    // Enforce max stack size
    while (_undoStack.length > maxSize) {
      _undoStack.removeAt(0);
    }
  }

  /// Undoes the last change and returns the previous state.
  ///
  /// Returns null if there's nothing to undo.
  /// Moves the current state to the redo stack.
  T? undo() {
    if (!canUndo) return null;

    // Move current state to redo stack
    final currentState = _undoStack.removeLast();
    _redoStack.add(currentState);

    // Return the previous state (which becomes current)
    return _undoStack.last;
  }

  /// Redoes a previously undone change and returns the redone state.
  ///
  /// Returns null if there's nothing to redo.
  /// Moves the state from redo stack back to undo stack.
  T? redo() {
    if (!canRedo) return null;

    // Move state from redo back to undo
    final stateToRedo = _redoStack.removeLast();
    _undoStack.add(stateToRedo);

    // Return the redone state (which becomes current)
    return stateToRedo;
  }

  /// Clears both undo and redo stacks.
  void clear() {
    _undoStack.clear();
    _redoStack.clear();
  }

  /// Gets the current state without modifying the stacks.
  ///
  /// Returns null if no state has been pushed yet.
  T? get current => _undoStack.isEmpty ? null : _undoStack.last;
}
