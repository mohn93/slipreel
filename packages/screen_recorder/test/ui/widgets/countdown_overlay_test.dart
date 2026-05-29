import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/countdown_controller.dart';
import 'package:screen_recorder/ui/widgets/countdown_overlay.dart';

void main() {
  testWidgets('renders the remaining number while active', (tester) async {
    final ctrl = CountdownController();
    await tester.pumpWidget(ProviderScope(
      overrides: [countdownControllerProvider.overrideWith((ref) => ctrl)],
      child: const MaterialApp(home: Scaffold(body: CountdownOverlay())),
    ));
    ctrl.run(seconds: 3, onComplete: () {});
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('renders nothing when inactive', (tester) async {
    final ctrl = CountdownController();
    await tester.pumpWidget(ProviderScope(
      overrides: [countdownControllerProvider.overrideWith((ref) => ctrl)],
      child: const MaterialApp(home: Scaffold(body: CountdownOverlay())),
    ));
    await tester.pump();
    expect(find.text('3'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('Cancel button calls controller.cancel', (tester) async {
    final ctrl = CountdownController();
    await tester.pumpWidget(ProviderScope(
      overrides: [countdownControllerProvider.overrideWith((ref) => ctrl)],
      child: const MaterialApp(home: Scaffold(body: CountdownOverlay())),
    ));
    ctrl.run(seconds: 3, onComplete: () {});
    await tester.pump();
    expect(ctrl.state.active, isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(ctrl.state.active, isFalse);
  });
}
