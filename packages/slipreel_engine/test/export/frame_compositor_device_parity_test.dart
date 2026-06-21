// packages/slipreel_engine/test/export/frame_compositor_device_parity_test.dart
//
// Regression guard: the export compositor and the shared pure function
// `resolveDeviceFrameLayout` must produce identical geometry (videoRect,
// bezelRect) for the same inputs.  If the compositor ever picks the wrong
// orientation, drops adjustSize, or passes wrong padding/aspect, this test
// fails.  The only legitimate delta is sub-pixel even-rounding of totalSize
// (≤1px per axis), which is also asserted.
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';
import 'package:slipreel_engine/rendering/device_frame_matcher.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

// Same fixture catalog as frame_compositor_device_test.dart
DeviceFrameCatalog _catalog() => const DeviceFrameCatalog([
      DeviceFrameEntry(
        id: 'test-phone',
        family: 'Test Phone',
        kind: 'phone',
        screenWidth: 100,
        screenHeight: 220,
        colors: [
          DeviceFrameColorVariant(
            id: 'black',
            name: 'Black',
            swatch: Color(0xFF000000),
            portrait: DeviceFrameOrientationAsset(
              asset: 'test://bezel-p',
              bezelWidth: 120,
              bezelHeight: 240,
              screenRect: DeviceScreenRect(
                  l: 10 / 120, t: 10 / 240, r: 110 / 120, b: 230 / 240)),
            landscape: DeviceFrameOrientationAsset(
              asset: 'test://bezel-l',
              bezelWidth: 240,
              bezelHeight: 120,
              screenRect: DeviceScreenRect(
                  l: 10 / 240, t: 10 / 120, r: 230 / 240, b: 110 / 120)),
          ),
        ],
      ),
    ]);

EditorProjectState _state({bool adjustSize = true}) =>
    EditorProjectState.defaults().copyWith(
      windowFrame: WindowFrame.none().copyWith(
        deviceFrameId: 'test-phone',
        deviceFrameColor: 'black',
        deviceFrameAdjustSize: adjustSize,
      ),
    );

FrameCompositor _compositor(EditorProjectState state) => FrameCompositor(
      projectState: state,
      cursorRecording: CursorRecording(),
      metadata: RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(0),
        widthPx: 100,
        heightPx: 220,
        fps: 60,
        isDeviceCapture: true,
      ),
      videoSize: const Size(100, 220),
      fps: 60,
      deviceFrameCatalog: _catalog(),
    );

void _assertRectsMatch(Rect actual, Rect expected, String label) {
  expect(actual.left, closeTo(expected.left, 0.001), reason: '$label.left');
  expect(actual.top, closeTo(expected.top, 0.001), reason: '$label.top');
  expect(actual.right, closeTo(expected.right, 0.001), reason: '$label.right');
  expect(actual.bottom, closeTo(expected.bottom, 0.001), reason: '$label.bottom');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final adjustSize in [true, false]) {
    test(
        'preview==export parity: videoRect & bezelRect match resolveDeviceFrameLayout '
        '(adjustSize=$adjustSize)', () {
      final state = _state(adjustSize: adjustSize);
      final comp = _compositor(state);

      // Compositor must have resolved a plan.
      expect(comp.deviceFramePlan, isNotNull,
          reason: 'FrameCompositor must resolve a DeviceFrameRenderPlan');

      final plan = comp.deviceFramePlan!;

      // Independently compute the expected layout using the same inputs the
      // compositor should use: portrait orientation (100×220 is portrait),
      // WindowFrame.padding, project outputAspect, deviceFrameAdjustSize.
      final videoSize = const Size(100, 220);
      final entry = _catalog().entryById('test-phone')!;
      final color = entry.colorById('black')!;
      final expectedAsset = recordingIsPortrait(videoSize)
          ? color.portrait
          : color.landscape;

      final expectedLayout = resolveDeviceFrameLayout(
        asset: expectedAsset,
        recordingSize: videoSize,
        padding: state.windowFrame.padding,
        aspect: state.outputAspect,
        adjustSize: state.windowFrame.deviceFrameAdjustSize,
      );

      // 1. The compositor must have picked the same orientation asset.
      expect(plan.asset.asset, equals(expectedAsset.asset),
          reason: 'compositor must pick portrait asset for 100×220 recording');

      // 2. videoRect must be identical to the independently computed layout.
      _assertRectsMatch(
        plan.layout.videoRect,
        expectedLayout.videoRect,
        'videoRect',
      );

      // 3. bezelRect must be identical.
      _assertRectsMatch(
        plan.layout.bezelRect,
        expectedLayout.bezelRect,
        'bezelRect',
      );

      // 4. totalSize (even-rounded) must be within 1px of layout.canvasSize on
      //    each axis — the only legitimate preview/export difference.
      expect(comp.totalSize.width,
          closeTo(expectedLayout.canvasSize.width, 1.0),
          reason: 'totalSize.width within 1px of canvasSize.width');
      expect(comp.totalSize.height,
          closeTo(expectedLayout.canvasSize.height, 1.0),
          reason: 'totalSize.height within 1px of canvasSize.height');

      // 5. Sanity: totalSize dimensions are even (yuv420p requirement).
      expect(comp.totalSize.width.toInt() % 2, equals(0),
          reason: 'totalSize.width must be even');
      expect(comp.totalSize.height.toInt() % 2, equals(0),
          reason: 'totalSize.height must be even');
    });
  }
}
