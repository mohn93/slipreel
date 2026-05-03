import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/segmented_button.dart';

void main() {
  final options = [
    (value: 'a', label: 'Alpha', tooltip: null),
    (value: 'b', label: 'Beta', tooltip: null),
    (value: 'c', label: 'Gamma', tooltip: 'disabled option'),
  ];

  Widget build({
    required String selected,
    required ValueChanged<String> onChanged,
    Set<String> disabled = const {},
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ExportSegmentedButton<String>(
          options: options,
          value: selected,
          onChanged: onChanged,
          disabled: disabled,
        ),
      ),
    );
  }

  testWidgets('renders all option labels', (tester) async {
    await tester.pumpWidget(build(selected: 'a', onChanged: (_) {}));
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
  });

  testWidgets('tapping unselected option fires onChanged with that value',
      (tester) async {
    String? fired;
    await tester.pumpWidget(
      build(selected: 'a', onChanged: (v) => fired = v),
    );
    await tester.tap(find.byKey(const ValueKey('seg_btn_b')));
    await tester.pump();
    expect(fired, 'b');
  });

  testWidgets('tapping already-selected option does not fire onChanged',
      (tester) async {
    var callCount = 0;
    await tester.pumpWidget(
      build(selected: 'a', onChanged: (_) => callCount++),
    );
    await tester.tap(find.byKey(const ValueKey('seg_btn_a')));
    await tester.pump();
    expect(callCount, 0);
  });

  testWidgets('tapping disabled option does not fire onChanged', (tester) async {
    String? fired;
    await tester.pumpWidget(
      build(
        selected: 'a',
        onChanged: (v) => fired = v,
        disabled: {'c'},
      ),
    );
    await tester.tap(find.byKey(const ValueKey('seg_btn_c')));
    await tester.pump();
    expect(fired, isNull);
  });

  testWidgets('selected button has purple border key visible', (tester) async {
    await tester.pumpWidget(build(selected: 'b', onChanged: (_) {}));
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('seg_btn_b')),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.border, isNotNull);
    final border = decoration.border! as Border;
    expect(border.top.color, const Color(0xFF8B5CF6));
  });

  testWidgets('unselected button has no border', (tester) async {
    await tester.pumpWidget(build(selected: 'b', onChanged: (_) {}));
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('seg_btn_a')),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.border, isNull);
  });

  testWidgets('disabled button renders at 0.4 opacity', (tester) async {
    await tester.pumpWidget(
      build(selected: 'a', onChanged: (_) {}, disabled: {'c'}),
    );
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('seg_btn_c')),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, 0.4);
  });

  testWidgets('disabled option has Semantics with enabled=false', (tester) async {
    await tester.pumpWidget(
      build(selected: 'a', onChanged: (_) {}, disabled: {'c'}),
    );
    // The Semantics widget wraps the GestureDetector (key seg_btn_c) as an
    // ancestor.
    final semanticsNodes = tester.widgetList<Semantics>(
      find.ancestor(
        of: find.byKey(const ValueKey('seg_btn_c')),
        matching: find.byType(Semantics),
      ),
    );
    // At least one Semantics ancestor should have enabled=false.
    expect(
      semanticsNodes.any((s) => s.properties.enabled == false),
      isTrue,
    );
  });
}
