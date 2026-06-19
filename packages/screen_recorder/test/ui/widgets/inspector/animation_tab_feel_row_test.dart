import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/animation_tab.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/feel_variant.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

Widget _app(List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: const MaterialApp(
        home: Scaffold(body: FeelAbRow()),
      ),
    );

void main() {
  final overrides = <Override>[
    editorProjectControllerProvider.overrideWith(
      (ref) => EditorProjectController(initial: EditorProjectState.defaults()),
    ),
  ];

  testWidgets('FeelAbRow shows label and cycles to next feel', (tester) async {
    await tester.pumpWidget(_app(overrides));
    await tester.pump();

    expect(find.text('Feel A/B (dev)'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);

    await tester.tap(find.byTooltip('Next feel'));
    await tester.pump();

    expect(find.text(FeelVariant.candidates[1].label), findsOneWidget);
    expect(find.text('Studio Soft'), findsOneWidget);
  });

  test('picker filter excludes experimental styles', () {
    expect(
      ScreenAnimationStyle.values.where((s) => !s.experimental).toList(),
      [ScreenAnimationStyle.focused, ScreenAnimationStyle.smooth],
    );
    expect(
      CursorAnimationStyle.values.where((s) => !s.experimental).toList(),
      [
        CursorAnimationStyle.smooth,
        CursorAnimationStyle.medium,
        CursorAnimationStyle.rapid,
        CursorAnimationStyle.none,
      ],
    );
  });
}
