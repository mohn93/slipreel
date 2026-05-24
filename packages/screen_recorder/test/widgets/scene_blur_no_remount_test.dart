@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression pin for the "camera jump mid-zoom" bug.
///
/// `SceneBlurOverlay._buildBody` used to return the bare `child`
/// (the [PlaybackCanvas]) when there was no smear to draw
/// (`!wantsPass`, no shader program, or `!signal.hasMotion`), and a
/// `Stack[RepaintBoundary(child), painter]` when there was. Toggling
/// between those two tree shapes changed the child's slot type, so
/// Flutter REMOUNTED PlaybackCanvas — which recreates its
/// `ScenePassBuilder`/`ZoomFocalController`, snapping the camera focal
/// back to the zoom rect's centre. With the deterministic blur signal
/// hitting `hasMotion == false` on every brief cursor pause, that
/// toggle fired constantly, producing visible camera jumps (focal
/// teleporting ~hundreds of px in one frame, `snap=init` in the focal
/// trace).
///
/// The fix keeps `child` at a STABLE slot: `_buildBody` always returns
/// the same `Stack` with `child` hosted under the keyed
/// `RepaintBoundary` at index 0, and only adds/removes the smear
/// painter on top. This source-level test pins that invariant — a
/// bare `return child;` inside `_buildBody` reintroduces the remount.
void main() {
  test(
    'SceneBlurOverlay._buildBody never returns bare child (would remount '
    'PlaybackCanvas and reset the camera focal)',
    () {
      final src =
          File('lib/ui/widgets/scene_blur_overlay.dart').readAsStringSync();

      // Isolate the _buildBody method body.
      final start = src.indexOf('Widget _buildBody(');
      expect(start, greaterThanOrEqualTo(0),
          reason: '_buildBody must exist in scene_blur_overlay.dart');
      // The next method after _buildBody is _computeSignal.
      final end = src.indexOf('SceneMotionBlurSignal _computeSignal(', start);
      expect(end, greaterThan(start),
          reason: 'expected _computeSignal to follow _buildBody');
      final body = src.substring(start, end);

      expect(
        body.contains('return child;'),
        isFalse,
        reason: 'a bare `return child;` toggles _buildBody between '
            '`child` and `Stack[...child...]`, which remounts '
            'PlaybackCanvas and snaps the camera focal to rect.center. '
            'Host child at a stable slot (the keyed RepaintBoundary in '
            'the Stack) on every path instead.',
      );

      // The stable host must be present.
      expect(
        body.contains('RepaintBoundary(key: _boundaryKey, child: child)'),
        isTrue,
        reason: 'child must always be hosted under the keyed '
            'RepaintBoundary so its element (and the camera spring '
            'state) is preserved across smear on/off transitions.',
      );
    },
  );
}
