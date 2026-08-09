@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Preview-side half of the cursor-blur parity contract (the engine
/// half lives in slipreel_engine's `cursor_blur_parity_test.dart`).
///
/// PlaybackCanvas/PlaybackScreen must feed the accumulation painter the
/// shared engine constants — a hard-coded stamp count or exposure here
/// is how preview (32 stamps) and export (8 stamps) silently diverged.
void main() {
  test(
    'PlaybackCanvas defaults its stamp count to the shared engine '
    'constant',
    () {
      final source = File('lib/ui/widgets/zoom/playback_canvas.dart')
          .readAsStringSync();
      expect(
        source.contains(
            'this.accumulationSampleCount = kCursorBlurStampCount'),
        isTrue,
        reason: 'The preview stamp count must come from '
            'kCursorBlurStampCount so export (which reads the same '
            'constant) stays WYSIWYG.',
      );
    },
  );

  test(
    'PlaybackScreen passes the shared base exposure, not a literal',
    () {
      final source =
          File('lib/ui/screens/playback_screen.dart').readAsStringSync();
      expect(
        source.contains('accumulationExposureMs: kCursorBlurBaseExposureMs'),
        isTrue,
        reason: 'The 150 ms virtual shutter must be single-sourced from '
            'the engine; export scales the same constant by intensity.',
      );
      expect(
        RegExp(r'accumulationExposureMs:\s*[\d.]').hasMatch(source),
        isFalse,
        reason: 'A literal exposure here can silently diverge from the '
            'export path.',
      );
    },
  );
}
