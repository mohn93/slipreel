import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/editor_history_controller.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

void main() {
  group('EditorHistoryController', () {
    test('canUndo / canRedo are false immediately after start()', () {
      final controller = EditorProjectController();
      final history = EditorHistoryController(controller: controller);
      history.start();
      expect(history.canUndo, isFalse,
          reason: 'A fresh history with only the initial-floor entry has '
              'nothing to undo past');
      expect(history.canRedo, isFalse);
      history.dispose();
    });

    test(
      'a single mutation past the coalesce window pushes one history entry',
      () {
        fakeAsync((async) {
          final controller = EditorProjectController();
          final history = EditorHistoryController(
            controller: controller,
            coalesceWindow: const Duration(milliseconds: 200),
          );
          history.start();

          controller.setCursorSize(5.0);
          // Before the coalesce window elapses, the new entry hasn't
          // been committed yet — a fast Cmd-Z right now would still
          // pick up the pending edit (handled by undo()'s flush).
          expect(history.canUndo, isFalse);

          async.elapse(const Duration(milliseconds: 250));
          expect(history.canUndo, isTrue,
              reason: 'After the coalesce window, the mutation is in '
                  'history and undo can restore the initial floor');
          history.dispose();
        });
      },
    );

    test(
      'rapid mutations within the coalesce window collapse into a single '
      'history entry (slider-drag scenario)',
      () {
        fakeAsync((async) {
          final controller = EditorProjectController();
          final history = EditorHistoryController(
            controller: controller,
            coalesceWindow: const Duration(milliseconds: 200),
          );
          history.start();

          // 10 fast mutations within the coalesce window
          for (var i = 1; i <= 10; i++) {
            controller.setCursorSize(i.toDouble());
            async.elapse(const Duration(milliseconds: 10));
          }
          // 100 ms elapsed so far; window not yet exceeded.
          expect(history.canUndo, isFalse);

          async.elapse(const Duration(milliseconds: 200));

          // After window, ONE entry committed.
          expect(history.canUndo, isTrue);
          history.undo();
          expect(controller.state.cursorSize, equals(2.0),
              reason:
                  'Undo must restore the initial floor (default cursorSize), '
                  'not bounce through intermediate slider positions');
          history.dispose();
        });
      },
    );

    test('undo + redo round-trip restores intermediate state', () {
      fakeAsync((async) {
        final controller = EditorProjectController();
        final history = EditorHistoryController(
          controller: controller,
          coalesceWindow: const Duration(milliseconds: 100),
        );
        history.start();

        controller.setCursorSize(3.0);
        async.elapse(const Duration(milliseconds: 200));
        controller.setMotionBlur(0.4);
        async.elapse(const Duration(milliseconds: 200));

        expect(controller.state.cursorSize, 3.0);
        expect(controller.state.motionBlur, 0.4);
        expect(history.canUndo, isTrue);

        // Undo motion-blur change
        history.undo();
        expect(controller.state.motionBlur, equals(0.0),
            reason: 'Motion blur reverts to default after first undo');
        expect(controller.state.cursorSize, 3.0,
            reason: 'Cursor size still reflects earlier change');

        // Undo cursor size change
        history.undo();
        expect(controller.state.cursorSize, 2.0,
            reason: 'Cursor size reverts to default (initial floor)');
        expect(history.canUndo, isFalse);

        // Redo cursor size
        history.redo();
        expect(controller.state.cursorSize, 3.0);

        // Redo motion blur
        history.redo();
        expect(controller.state.motionBlur, 0.4);
        history.dispose();
      });
    });

    test('new mutation after undo clears the redo stack', () {
      fakeAsync((async) {
        final controller = EditorProjectController();
        final history = EditorHistoryController(
          controller: controller,
          coalesceWindow: const Duration(milliseconds: 100),
        );
        history.start();

        controller.setCursorSize(3.0);
        async.elapse(const Duration(milliseconds: 200));
        controller.setCursorSize(5.0);
        async.elapse(const Duration(milliseconds: 200));

        history.undo(); // back to 3.0
        expect(history.canRedo, isTrue);

        // Mutate a different field; this branches history.
        controller.setMotionBlur(0.3);
        async.elapse(const Duration(milliseconds: 200));

        expect(history.canRedo, isFalse,
            reason:
                'Branching history (mutation after undo) must clear redo');
        history.dispose();
      });
    });

    test('applying an undo does not push a new history entry', () {
      // Otherwise the undo itself becomes a state change that pushes
      // and the user is stuck in a loop.
      fakeAsync((async) {
        final controller = EditorProjectController();
        final history = EditorHistoryController(
          controller: controller,
          coalesceWindow: const Duration(milliseconds: 100),
        );
        history.start();

        controller.setCursorSize(4.0);
        async.elapse(const Duration(milliseconds: 200));
        // One entry above the floor.

        history.undo();
        async.elapse(const Duration(milliseconds: 200));
        // The undo applied the previous state via the controller, which
        // re-fires the listener. If we mishandled this, the new state
        // would have been pushed as a fresh history entry and canUndo
        // would still be true.
        expect(history.canUndo, isFalse,
            reason: 'After undoing back to the floor, nothing left to undo');
        expect(history.canRedo, isTrue,
            reason: 'The undone state is now redoable');
        history.dispose();
      });
    });

    test(
      'notifies listeners on push and on undo/redo (drives toolbar '
      'button enable/disable rebuilds)',
      () {
        fakeAsync((async) {
          final controller = EditorProjectController();
          final history = EditorHistoryController(
            controller: controller,
            coalesceWindow: const Duration(milliseconds: 100),
          );
          history.start();
          var notifies = 0;
          history.addListener(() => notifies++);

          controller.setCursorSize(5.0);
          async.elapse(const Duration(milliseconds: 200));
          // First push fires one notify.
          expect(notifies, 1);

          history.undo();
          // Undo applies + notifies.
          expect(notifies, 2);

          history.redo();
          expect(notifies, 3);
          history.dispose();
        });
      },
    );

    test(
      'a value-equal republication does not create a phantom undo entry',
      () {
        // Regression: history deduped by identical(), so a publish of a
        // new-but-value-equal state (e.g. replace(current.copyWith()))
        // landed as a fresh entry — Cmd-Z lit up and visibly did
        // nothing for one press.
        fakeAsync((async) {
          final controller = EditorProjectController();
          final history = EditorHistoryController(
            controller: controller,
            coalesceWindow: const Duration(milliseconds: 100),
          );
          history.start();

          controller.replace(controller.current.copyWith());
          async.elapse(const Duration(milliseconds: 200));

          expect(history.canUndo, isFalse,
              reason: 'A state equal to the previous history entry must '
                  'not be pushed as a new undoable atom');
          history.dispose();
        });
      },
    );

    test('undo flushes a pending coalesced change before reverting', () {
      // Scenario: user drags a slider, then immediately Cmd-Z without
      // waiting for the coalesce window to expire. The pending edit
      // must land in history first, otherwise the user would skip
      // over their just-finished edit and undo something older.
      fakeAsync((async) {
        final controller = EditorProjectController();
        final history = EditorHistoryController(
          controller: controller,
          coalesceWindow: const Duration(milliseconds: 200),
        );
        history.start();

        // First completed edit
        controller.setCursorSize(3.0);
        async.elapse(const Duration(milliseconds: 250));

        // Second edit, mid-coalesce
        controller.setCursorSize(7.0);
        async.elapse(const Duration(milliseconds: 50));
        expect(history.canUndo, isTrue); // first edit is in history

        // User hits Cmd-Z before the coalesce window expires.
        history.undo();
        // The undo must take us back to cursorSize=3.0 (the previous
        // completed entry), not all the way to the initial floor.
        expect(controller.state.cursorSize, equals(3.0));
        history.dispose();
      });
    });
  });
}
