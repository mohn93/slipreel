import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/look_template.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/state/editor_look.dart';

void main() {
  test('built-ins are Clean/Showcase/Minimal in order', () {
    final b = builtinLookTemplates();
    expect(b.map((t) => t.id).toList(),
        [kBuiltinCleanId, kBuiltinShowcaseId, kBuiltinMinimalId]);
    expect(b.every((t) => t.builtIn), isTrue);
    expect(b[0].look.windowFrame.name, WindowFrame.rounded().name);
    expect(b[0].look.defaultZoomLook, ZoomLook.classic);
    expect(b[1].look.defaultZoomLook, ZoomLook.showcase);
    expect(b[2].look.defaultZoomLook, ZoomLook.flat);
  });

  test('user template JSON round-trips', () {
    final t = LookTemplate(
      id: 'abc',
      name: 'My Look',
      builtIn: false,
      look: EditorLook.defaults(),
      updatedAt: DateTime.utc(2026, 9, 6),
    );
    final restored = LookTemplate.fromJson(t.toJson());
    expect(restored, t);
  });
}
