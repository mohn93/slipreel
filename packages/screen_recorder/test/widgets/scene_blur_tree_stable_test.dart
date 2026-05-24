@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/scene_blur_overlay.dart';

/// Behavioral half of the "camera jump" regression guard (the other
/// half is the structural `scene_blur_no_remount_test`).
///
/// The bug: `SceneBlurOverlay` hosted its child (the `PlaybackCanvas`)
/// at one tree slot when there was no smear and a different slot
/// (nested under a `Stack`) when there was. Toggling those shapes
/// remounted `PlaybackCanvas`, recreating its `ZoomFocalController`
/// and snapping the camera focal to the zoom rect's centre — a visible
/// mid-zoom jump every time the smear turned on/off.
///
/// `buildSceneBlurTree` is the shared assembler that keeps the framed
/// child at a STABLE slot (Stack child 0) whether or not the smear
/// overlay is present. This test pumps it through repeated overlay
/// add/remove cycles and asserts the child's [State] is never
/// recreated — i.e. no remount, so the live camera spring survives.
void main() {
  testWidgets(
    'buildSceneBlurTree keeps the framed child mounted across smear '
    'overlay add/remove (no remount → camera spring preserved)',
    (tester) async {
      _CountingChildState.initCount = 0;

      Widget tree(bool withSmear) => Directionality(
            textDirection: TextDirection.ltr,
            child: buildSceneBlurTree(
              framedChild: const _CountingChild(),
              smearOverlay: withSmear ? const SizedBox.shrink() : null,
            ),
          );

      await tester.pumpWidget(tree(false));
      expect(_CountingChildState.initCount, 1,
          reason: 'child mounts once initially');

      // Smear ON (camera in motion) — overlay layered on top.
      await tester.pumpWidget(tree(true));
      expect(_CountingChildState.initCount, 1,
          reason: 'adding the smear overlay must NOT remount the child');

      // Smear OFF (cursor pauses, signal hits hasMotion=false).
      await tester.pumpWidget(tree(false));
      expect(_CountingChildState.initCount, 1,
          reason: 'removing the smear overlay must NOT remount the child');

      // The real-world failure mode: rapid on/off through a zoom hold.
      for (var i = 0; i < 6; i++) {
        await tester.pumpWidget(tree(i.isEven));
      }
      expect(_CountingChildState.initCount, 1,
          reason: 'repeated smear toggles must never remount the child '
              '(each remount would reset the camera focal to rect.center)');
    },
  );
}

class _CountingChild extends StatefulWidget {
  const _CountingChild();

  @override
  State<_CountingChild> createState() => _CountingChildState();
}

class _CountingChildState extends State<_CountingChild> {
  static int initCount = 0;

  @override
  void initState() {
    super.initState();
    initCount++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
