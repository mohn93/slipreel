@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/accumulation_cursor_painter.dart';

/// Preview and export must run the cursor accumulation blur with the
/// same stamp count and base exposure — they diverged once (preview 32
/// stamps, export 8) and fast cursor movement shipped as discrete
/// ghosts instead of the ribbon the user previewed.
///
/// Follows the structural-assertion pattern of
/// `frame_compositor_cursor_painter_test.dart`: pixel-asserting stamp
/// counts is flaky, but the parity rule is simple — both sides read
/// the shared constants, neither hard-codes a literal.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shared cursor-blur constants carry the production values', () {
    expect(kCursorBlurStampCount, 32,
        reason: 'Production preview has always rendered 32 stamps; the '
            'shared constant must match what users see');
    expect(kCursorBlurBaseExposureMs, 150.0);
  });

  test(
    'FrameCompositor reads the shared stamp count and base exposure '
    '(no literal sampleCount/exposure in the export cursor path)',
    () {
      final source =
          File('lib/export/frame_compositor.dart').readAsStringSync();

      expect(
        source.contains('sampleCount: kCursorBlurStampCount'),
        isTrue,
        reason: 'Export must pass the shared constant so preview==export '
            'holds. If you intentionally changed the stamp count, change '
            'kCursorBlurStampCount so preview follows.',
      );
      expect(
        RegExp(r'sampleCount:\s*\d').hasMatch(source),
        isFalse,
        reason: 'A literal stamp count in the export path is exactly how '
            'the 8-vs-32 parity break happened.',
      );
      expect(
        source.contains('kCursorBlurBaseExposureMs'),
        isTrue,
        reason: 'Export must scale the shared base exposure, not a '
            'duplicated 150.0 literal.',
      );
    },
  );
}
