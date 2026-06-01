import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/app_palette_controller.dart';
import 'package:screen_recorder/state/app_palette_store.dart';
import 'package:screen_recorder/ui/screens/theme_playground_screen.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

class _NoOpStore implements AppPaletteStore {
  @override
  String get path => '<noop>';
  @override
  Future<PaletteId?> load() async => null;
  @override
  Future<void> save(PaletteId id) async {}
}

Widget _wrap(Widget child, {PaletteId initial = PaletteId.midnight}) {
  final store = _NoOpStore();
  return ProviderScope(
    overrides: [
      appPaletteControllerProvider.overrideWith(
        (ref) => AppPaletteController(store: store, initial: initial),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        extensions: [AppPalette.byId(initial)],
        useMaterial3: true,
      ),
      home: child,
    ),
  );
}

void main() {
  testWidgets('renders three swatch tiles labeled with palette names',
      (tester) async {
    await tester.pumpWidget(_wrap(const ThemePlaygroundScreen()));
    expect(find.text('Midnight'), findsOneWidget);
    expect(find.text('Carbon'), findsOneWidget);
    expect(find.text('Obsidian'), findsOneWidget);
  });

  testWidgets('active tile shows a check icon; others do not', (tester) async {
    await tester.pumpWidget(
      _wrap(const ThemePlaygroundScreen(), initial: PaletteId.carbon),
    );
    final carbonTile = find.ancestor(
      of: find.text('Carbon'),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(of: carbonTile, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    final midnightTile = find.ancestor(
      of: find.text('Midnight'),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(of: midnightTile, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
  });

  testWidgets('tapping a swatch fires controller.select', (tester) async {
    await tester.pumpWidget(_wrap(const ThemePlaygroundScreen()));
    final obsidianTile = find.ancestor(
      of: find.text('Obsidian'),
      matching: find.byType(InkWell),
    );
    await tester.tap(obsidianTile);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ThemePlaygroundScreen)),
    );
    expect(container.read(appPaletteControllerProvider), PaletteId.obsidian);
  });

  testWidgets('token grid renders 10 hex labels', (tester) async {
    await tester.pumpWidget(_wrap(const ThemePlaygroundScreen()));
    final hexFinder = find.byWidgetPredicate(
      (w) => w is Text &&
          w.data != null &&
          RegExp(r'^#[0-9A-Fa-f]{6,8}$').hasMatch(w.data!),
    );
    expect(hexFinder, findsNWidgets(10));
  });
}
