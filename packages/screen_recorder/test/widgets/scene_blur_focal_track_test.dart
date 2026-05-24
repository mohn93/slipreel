@TestOn('vm')
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SceneBlurOverlay samples DeterministicFocalTrack, not raw cursor, '
      'for the focal (cursor-follow crack regression)', () {
    final src =
        File('lib/ui/widgets/scene_blur_overlay.dart').readAsStringSync();
    expect(src.contains('DeterministicFocalTrack'), isTrue,
        reason: 'the pan vector must measure the spring camera focal via the '
            'deterministic track; sampling raw cursor made the smear diverge '
            'from on-screen motion at zoom enter/exit');
    expect(src.contains('.focalAt('), isTrue,
        reason: 'focal must come from track.focalAt(t)');
  });
}
