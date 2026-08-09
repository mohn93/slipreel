@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Scene-blur exposure parity contract, preview side.
///
/// The export computes its exposure window as
/// `exposureMs * sceneBlurExposureScale(master, channel)` — the CUBIC
/// response curves. The preview canvas multiplies its inputs RAW
/// (`effectiveSceneMotionBlur * screenMovementBlur`), which only matches
/// because PlaybackScreen pre-curves every value through
/// `sceneBlurMasterResponse` / `sceneBlurChannelResponse` before handing
/// it to PlaybackCanvas. Passing the raw project values instead would
/// silently stretch the preview's exposure window ~4x past the export's.
/// (Verified consistent 2026-08-09 while refuting the review claim that
/// speed normalization diverges preview vs export.)
void main() {
  test('PlaybackScreen pre-curves master and channel blur values', () {
    // Source-level contract: this reads the screen's source relative to the
    // package root (how `flutter test` runs it). Assert existence first so a
    // wrong CWD — or a genuine rename/move of the screen — fails with an
    // actionable message instead of an opaque FileSystemException. It must
    // still fail loudly (not skip): a moved file means this parity check
    // needs updating.
    final file = File('lib/ui/screens/playback_screen.dart');
    expect(file.existsSync(), isTrue,
        reason: 'run from the screen_recorder package root; if '
            'playback_screen.dart moved, update this parity contract');
    final source = file.readAsStringSync();
    expect(
      source.contains('sceneBlurMasterResponse(project.motionBlur)'),
      isTrue,
      reason: 'master value must go through the shared response curve',
    );
    expect(
      source.contains(
        'sceneBlurChannelResponse(\n    project.screenMovementBlur,\n  )',
      ) ||
          source.contains(
            'sceneBlurChannelResponse(project.screenMovementBlur)',
          ) ||
          RegExp(
            r'sceneBlurChannelResponse\(\s*project\.screenMovementBlur,?\s*\)',
          ).hasMatch(source),
      isTrue,
      reason: 'movement channel must go through the shared response curve',
    );
    expect(
      RegExp(
        r'sceneBlurChannelResponse\(\s*project\.screenZoomBlur,?\s*\)',
      ).hasMatch(source),
      isTrue,
      reason: 'zoom channel must go through the shared response curve',
    );
    // The canvas must receive the CURVED values, not the raw ones.
    expect(source.contains('sceneMotionBlur: masterCurved'), isTrue);
    expect(source.contains('screenMovementBlur: screenMovementCurved'), isTrue);
    expect(source.contains('screenZoomBlur: screenZoomCurved'), isTrue);
    expect(
      source.contains('screenMovementBlur: project.screenMovementBlur'),
      isFalse,
      reason: 'raw channel values must never reach PlaybackCanvas',
    );
  });
}
