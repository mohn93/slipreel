import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/look_template.dart';
import 'package:screen_recorder/state/look_template_controller.dart';
import 'package:screen_recorder/state/look_template_store.dart';
import 'package:screen_recorder/ui/widgets/inspector/template_row.dart';
import 'package:slipreel_engine/state/editor_look.dart';

void main() {
  testWidgets('overflow menu hides Update/Rename/Delete for built-ins',
      (tester) async {
    // A path string only — never touched. This test only opens the
    // overflow menu, it never triggers a save/update/rename/delete, so
    // the store never performs any real file I/O.
    final store = LookTemplateStore(
      filePath: '/tmp/template_row_test_look_templates.json',
    );
    final controller = LookTemplateController(
      store: store,
      initial: const LookTemplateData(templates: [], selectedId: kBuiltinCleanId),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        lookTemplateControllerProvider.overrideWith((_) => controller),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: TemplateRow(
            onApply: (_) {},
            currentLook: EditorLook.defaults,
          ),
        ),
      ),
    ));
    // Open the overflow menu.
    await tester.tap(find.byKey(const Key('template-overflow')));
    await tester.pumpAndSettle();
    expect(find.text('Save as new template…'), findsOneWidget);
    expect(find.textContaining('Update'), findsNothing); // Clean is built-in
    expect(find.text('Rename…'), findsNothing);
    expect(find.text('Delete…'), findsNothing);
  });
}
