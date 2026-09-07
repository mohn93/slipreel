import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/editor_look.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  test('applyLook replaces look fields and restyles all zooms', () {
    // Seed a project with a zoom and a device frame set on the recording.
    final withDeviceFrame = EditorProjectState.defaults().copyWith(
      windowFrame: EditorProjectState.defaults()
          .windowFrame
          .copyWith(deviceFrameId: 'iphone-16-pro', deviceFrameColor: 'black'),
      zoomRegions: [
        ZoomRegion(
          rect: const Rect.fromLTWH(0, 0, 100, 100),
          startTime: const Duration(seconds: 1),
          duration: const Duration(seconds: 1),
          zoomLevel: 2.0,
        ),
      ],
    );
    final controller = EditorProjectController(initial: withDeviceFrame);

    // A look saved from a NON-device recording: modern frame, showcase zoom.
    final look = EditorLook.fromProject(
      EditorProjectState.defaults().copyWith(
        windowFrame: WindowFrame.modern(),
        defaultZoomLook: ZoomLook.showcase,
      ),
    );

    // A small videoSize keeps the 3D-tilt padding floor (see
    // `_enforce3DPaddingFloor`) from renaming the frame to "Custom" —
    // that padding-floor interaction is a separate, already-tested
    // concern of `applyLookToAllZooms`, not of `applyLook` itself.
    controller.applyLook(look, videoSize: const Size(400, 300));

    // Look applied.
    expect(controller.current.defaultZoomLook, ZoomLook.showcase);
    // Frame name came from the template...
    expect(controller.current.windowFrame.name, WindowFrame.modern().name);
    // ...but the recording's device frame was PRESERVED, not wiped.
    expect(controller.current.windowFrame.deviceFrameId, 'iphone-16-pro');
    // Existing zoom restyled to the template's zoom look.
    expect(
      ZoomLook.of(controller.current.zoomRegions.first),
      ZoomLook.showcase,
    );
  });

  test('applyLook does not carry a template device frame onto a plain recording',
      () {
    final plain = EditorProjectController(
      initial: EditorProjectState.defaults(),
    );
    final look = EditorLook.fromProject(
      EditorProjectState.defaults().copyWith(
        windowFrame: EditorProjectState.defaults()
            .windowFrame
            .copyWith(deviceFrameId: 'iphone-16-pro'),
      ),
    );
    plain.applyLook(look, videoSize: const Size(1920, 1080));
    expect(plain.current.windowFrame.deviceFrameId, isNull);
  });
}
