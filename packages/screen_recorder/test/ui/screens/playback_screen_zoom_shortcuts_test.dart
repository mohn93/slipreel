import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

// The shortcut intents + activator/action factories live in
// zoom_shortcuts.dart (created in Step 4 below) so this test can wire
// them up without spinning the playback screen. Closures inject the
// scale getter/setter — no provider needed in the test.

import 'package:screen_recorder/ui/screens/zoom_shortcuts.dart';

void main() {
  testWidgets('Cmd = invokes setTimelineScale with currentScale * 1.25',
      (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => c),
      ],
      child: MaterialApp(
        home: Shortcuts(
          shortcuts: buildZoomShortcuts(),
          child: Actions(
            actions: buildZoomActions(
              getScale: () => c.current.timelineScale,
              setScale: (s) => c.setTimelineScale(s,
                  anchorTime: const Duration(seconds: 2)),
            ),
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(c.current.timelineScale, closeTo(1.25, 0.001));
  });

  testWidgets('Cmd - invokes setTimelineScale with currentScale / 1.25',
      (tester) async {
    final c = EditorProjectController();
    c.setTimelineScale(4.0);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => c),
      ],
      child: MaterialApp(
        home: Shortcuts(
          shortcuts: buildZoomShortcuts(),
          child: Actions(
            actions: buildZoomActions(
              getScale: () => c.current.timelineScale,
              setScale: (s) => c.setTimelineScale(s,
                  anchorTime: const Duration(seconds: 2)),
            ),
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(c.current.timelineScale, closeTo(3.2, 0.001));
  });

  testWidgets('Cmd + Shift + = (Cmd++) also invokes zoom in',
      (tester) async {
    final c = EditorProjectController();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => c),
      ],
      child: MaterialApp(
        home: Shortcuts(
          shortcuts: buildZoomShortcuts(),
          child: Actions(
            actions: buildZoomActions(
              getScale: () => c.current.timelineScale,
              setScale: (s) => c.setTimelineScale(s),
            ),
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(c.current.timelineScale, closeTo(1.25, 0.001));
  });

  testWidgets('Cmd = at scale=8.0 clamps to 8.0 (no overshoot)',
      (tester) async {
    final c = EditorProjectController();
    c.setTimelineScale(8.0);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => c),
      ],
      child: MaterialApp(
        home: Shortcuts(
          shortcuts: buildZoomShortcuts(),
          child: Actions(
            actions: buildZoomActions(
              getScale: () => c.current.timelineScale,
              setScale: (s) => c.setTimelineScale(s),
            ),
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(c.current.timelineScale, 8.0);
  });
}
