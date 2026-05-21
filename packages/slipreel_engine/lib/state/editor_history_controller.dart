import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/state/undo_redo_controller.dart';

/// Wraps an [EditorProjectController] with state-shaped undo/redo.
///
/// Subscribes to the controller's stream and debounces mutations into
/// history entries so a slider drag (which fires dozens of state
/// changes per second) lands as one undoable atom rather than one
/// entry per tick. [undo] and [redo] apply the chosen entry back
/// through `controller.replace(...)` and flag the apply so the
/// resulting publish doesn't recursively push a new entry.
class EditorHistoryController extends ChangeNotifier {
  EditorHistoryController({
    required this.controller,
    this.coalesceWindow = const Duration(milliseconds: 500),
    int maxHistory = 50,
  }) : _history = UndoRedoController<EditorProjectState>(maxSize: maxHistory);

  /// The notifier whose state forms the history timeline.
  final EditorProjectController controller;

  /// Time window inside which consecutive mutations collapse into one
  /// history entry. A drag's per-tick mutations all land inside this
  /// window, so the user undoes the whole drag in one Cmd-Z. Tuned by
  /// the caller (UI scrubbing might want a shorter window; bulk edit
  /// flows a longer one).
  final Duration coalesceWindow;

  final UndoRedoController<EditorProjectState> _history;
  bool _applyingHistory = false;
  Timer? _coalesceTimer;
  void Function()? _removeListener;

  /// Begin watching [controller]. Pushes the current state as the
  /// initial "floor" entry — [canUndo] is false until the next
  /// mutation is committed.
  void start() {
    _history.push(controller.state);
    _removeListener = controller.addListener(
      (state) {
        if (_applyingHistory) return;
        _scheduleCoalescedPush();
      },
      fireImmediately: false,
    );
  }

  /// Stop watching and release the timer.
  @override
  void dispose() {
    _coalesceTimer?.cancel();
    _removeListener?.call();
    _removeListener = null;
    super.dispose();
  }

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;

  /// Roll back to the previous history entry. Flushes any pending
  /// coalesced edit first so the user's most recent change is in
  /// history before stepping back over it.
  void undo() {
    _flushPending();
    final prev = _history.undo();
    if (prev == null) return;
    _apply(prev);
  }

  /// Step forward through history after a prior [undo].
  void redo() {
    _flushPending();
    final next = _history.redo();
    if (next == null) return;
    _apply(next);
  }

  void _scheduleCoalescedPush() {
    _coalesceTimer?.cancel();
    _coalesceTimer = Timer(coalesceWindow, _commitPending);
  }

  void _commitPending() {
    _coalesceTimer = null;
    final current = controller.state;
    // Avoid pushing duplicates — happens when a mutator is called
    // with the same value the state already has.
    if (identical(_history.current, current)) return;
    _history.push(current);
    // Notify listeners so toolbar Undo/Redo buttons re-enable as
    // history changes (otherwise the buttons stay disabled until
    // another widget rebuild happens to flow through).
    notifyListeners();
  }

  void _flushPending() {
    if (_coalesceTimer == null) return;
    _coalesceTimer!.cancel();
    _coalesceTimer = null;
    _commitPending();
  }

  void _apply(EditorProjectState state) {
    _applyingHistory = true;
    try {
      controller.replace(state);
    } finally {
      _applyingHistory = false;
    }
    notifyListeners();
  }
}
