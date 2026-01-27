import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/undo_redo_controller.dart';

void main() {
  group('UndoRedoController', () {
    test('push and undo states', () {
      final controller = UndoRedoController<int>();

      // Initially empty
      expect(controller.canUndo, false);
      expect(controller.canRedo, false);

      // Push first state
      controller.push(1);
      expect(controller.canUndo, false); // Only one state, nothing to undo to
      expect(controller.canRedo, false);

      // Push second state
      controller.push(2);
      expect(controller.canUndo, true); // Can undo to previous state
      expect(controller.canRedo, false);

      // Undo - should return previous state (1)
      final undoneState = controller.undo();
      expect(undoneState, 1);
      expect(controller.canUndo, false); // Back to first state
      expect(controller.canRedo, true); // Can redo
    });

    test('redo after undo', () {
      final controller = UndoRedoController<String>();

      controller.push('a');
      controller.push('b');
      controller.push('c');

      // Undo twice
      expect(controller.undo(), 'b');
      expect(controller.undo(), 'a');
      expect(controller.canUndo, false);
      expect(controller.canRedo, true);

      // Redo once
      final redoneState = controller.redo();
      expect(redoneState, 'b');
      expect(controller.canUndo, true);
      expect(controller.canRedo, true); // Still can redo to 'c'

      // Redo again
      final redoneState2 = controller.redo();
      expect(redoneState2, 'c');
      expect(controller.canUndo, true);
      expect(controller.canRedo, false); // No more redo available
    });

    test('clear redo stack on new push after undo', () {
      final controller = UndoRedoController<int>();

      controller.push(1);
      controller.push(2);
      controller.push(3);

      // Undo twice
      controller.undo(); // Back to 2
      controller.undo(); // Back to 1
      expect(controller.canRedo, true);

      // Push new state - should clear redo stack
      controller.push(10);
      expect(controller.canUndo, true);
      expect(controller.canRedo, false); // Redo stack cleared

      // Verify we can't redo to old states (2, 3)
      controller.undo();
      expect(controller.canUndo, false);
      expect(controller.canRedo, true);

      // Redo should give us 10, not 2
      expect(controller.redo(), 10);
    });

    test('max stack size enforcement', () {
      final controller = UndoRedoController<int>(maxStackSize: 3);

      // Push 5 states
      for (int i = 1; i <= 5; i++) {
        controller.push(i);
      }

      // Stack should only have last 3 states (3, 4, 5)
      // Current is 5, can undo to 4, then to 3
      expect(controller.canUndo, true);
      expect(controller.undo(), 4); // Undo to 4
      expect(controller.undo(), 3); // Undo to 3
      expect(controller.canUndo, false); // Can't undo further (1 and 2 were dropped)
    });

    test('undo with no history returns null', () {
      final controller = UndoRedoController<int>();

      expect(controller.canUndo, false);
      expect(controller.undo(), null);

      controller.push(1);
      expect(controller.canUndo, false); // Only one state
      expect(controller.undo(), null);
    });

    test('redo with no redo stack returns null', () {
      final controller = UndoRedoController<int>();

      expect(controller.canRedo, false);
      expect(controller.redo(), null);

      controller.push(1);
      controller.push(2);
      expect(controller.canRedo, false);
      expect(controller.redo(), null);
    });
  });
}
