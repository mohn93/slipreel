import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/caption_style_controls.dart';

void main() {
  testWidgets('toggling Show captions updates style.enabled', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: CaptionStyleControls()),
        ),
      ),
    );
    expect(
      container.read(editorProjectControllerProvider).captionStyle.enabled,
      isFalse,
    );
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(
      container.read(editorProjectControllerProvider).captionStyle.enabled,
      isTrue,
    );
  });
}
