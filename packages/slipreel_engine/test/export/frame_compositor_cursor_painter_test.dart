@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Production preview ([`PlaybackScreen`] in screen_recorder) hard-codes
/// `CursorBlurMode.accumulation` for cursor motion blur. Until this
/// test was added, export went through the legacy `CursorOverlayPainter`
/// (shader-stretched chord smear), giving a WYSIWYG break between what
/// the user edited and what shipped in the MP4 — bug #3 from the
/// architecture review.
///
/// This is a source-level structural assertion. The painters differ
/// most on curved paths, mid-window cursor-type changes, and click
/// press-pulses spanning the exposure window — properties that are
/// hard to pixel-assert without flake. The structural rule is simple:
/// FrameCompositor renders cursors through the same painter the
/// production preview uses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'FrameCompositor uses AccumulationCursorPainter, not the legacy '
    'CursorOverlayPainter (bug #3 — WYSIWYG between preview and export)',
    () {
      final source = File('lib/export/frame_compositor.dart')
          .readAsStringSync();

      expect(
        source.contains('AccumulationCursorPainter'),
        isTrue,
        reason: 'export must construct the same painter as the production '
            'preview (CursorBlurMode.accumulation in PlaybackScreen) so '
            'cursor motion-blur is WYSIWYG. If you intentionally switched '
            'export to a different painter, update PlaybackScreen too.',
      );

      // The shader painter is fine to use elsewhere (the playground
      // screen still A/B compares it), but it must not be the export's
      // cursor pipeline. Matching the constructor call site rather than
      // the class name lets `import ... show CursorOverlayPainter` slip
      // through for utility helpers (e.g. shader pre-warm).
      expect(
        source.contains('CursorOverlayPainter('),
        isFalse,
        reason: 'CursorOverlayPainter() construction in the export path '
            'reintroduces bug #3 (preview/export cursor-blur divergence). '
            'Use AccumulationCursorPainter to match production preview.',
      );
    },
  );
}
