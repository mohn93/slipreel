import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/state/editor_look.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  test('fromProject then withLook is identity for look fields', () {
    final base = EditorProjectState.defaults().copyWith(
      cursorSize: 4.0,
      cursorStyle: CursorStyle.dot,
      motionBlur: 0.3,
      outputAspect: OutputAspect.square1x1,
      windowFrame: WindowFrame.modern(),
      defaultZoomLook: ZoomLook.showcase,
    );
    final look = EditorLook.fromProject(base);
    final applied = EditorProjectState.defaults().withLook(look);

    expect(applied.cursorSize, 4.0);
    expect(applied.cursorStyle, CursorStyle.dot);
    expect(applied.motionBlur, 0.3);
    expect(applied.outputAspect, OutputAspect.square1x1);
    expect(applied.windowFrame, WindowFrame.modern());
    expect(applied.defaultZoomLook, ZoomLook.showcase);
    // Timeline is content, not look — untouched.
    expect(applied.timeline, EditorProjectState.defaults().timeline);
  });

  test('EditorLook JSON round-trips', () {
    final look = EditorLook.fromProject(
      EditorProjectState.defaults().copyWith(cursorSize: 3.3, motionBlur: 0.25),
    );
    final restored = EditorLook.fromJson(look.toJson());
    expect(restored, look);
  });

  test('withoutDeviceFrame clears device-frame fields but nothing else', () {
    final defaultLook = EditorLook.defaults();
    final framed = defaultLook.copyWith(
      windowFrame:
          defaultLook.windowFrame.copyWith(deviceFrameId: 'iphone-16-pro'),
      cursorSize: 5.5,
      defaultZoomLook: ZoomLook.showcase,
    );
    expect(framed.windowFrame.deviceFrameId, 'iphone-16-pro');

    final stripped = framed.withoutDeviceFrame();

    expect(stripped.windowFrame.deviceFrameId, isNull);
    expect(stripped.windowFrame.deviceFrameColor, isNull);
    // deviceFrameAdjustSize is untouched by clearDeviceFrame (copyWith only
    // resets it via an explicit new value), so it stays at whatever it was.
    expect(
      stripped.windowFrame.deviceFrameAdjustSize,
      framed.windowFrame.deviceFrameAdjustSize,
    );
    // Non-device-frame fields are untouched.
    expect(stripped.cursorSize, 5.5);
    expect(stripped.defaultZoomLook, ZoomLook.showcase);
  });
}
