// packages/screen_recorder/test/ui/widgets/canvas_toolbar/snap_toggle_pill_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:screen_recorder/state/snap_preference_controller.dart';
import 'package:screen_recorder/state/snap_preference_store.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/snap_toggle_pill.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Widget> appWith({required bool initial}) async {
    SharedPreferences.setMockInitialValues({});
    final store = SnapPreferenceStore(await SharedPreferences.getInstance());
    return ProviderScope(
      overrides: [
        snapPreferenceProvider.overrideWith(
          (ref) => SnapPreferenceController(store: store, initial: initial),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: SnapTogglePill())),
      ),
    );
  }

  testWidgets('renders with magnet icon and current state in tooltip',
      (tester) async {
    await tester.pumpWidget(await appWith(initial: true));
    expect(find.byTooltip('Snap to events: On'), findsOneWidget);
  });

  testWidgets('tooltip reflects off state', (tester) async {
    await tester.pumpWidget(await appWith(initial: false));
    expect(find.byTooltip('Snap to events: Off'), findsOneWidget);
  });

  testWidgets('tap toggles provider state', (tester) async {
    await tester.pumpWidget(await appWith(initial: true));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SnapTogglePill)),
    );
    expect(container.read(snapPreferenceProvider), isTrue);
    await tester.tap(find.byType(SnapTogglePill));
    await tester.pump();
    expect(container.read(snapPreferenceProvider), isFalse);
  });
}
