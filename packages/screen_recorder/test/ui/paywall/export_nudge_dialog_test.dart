import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/ui/paywall/export_nudge_dialog.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

// Minimal StateNotifier stand-in for LicensingController (mirrors the pattern
// in paywall_dialog_test.dart).
class _FakeController extends StateNotifier<EntitlementState>
    implements LicensingController {
  _FakeController() : super(const EntitlementSignedOut());
  int unlockCalls = 0;
  @override
  Future<bool> unlockExport() async {
    unlockCalls++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget _host(_FakeController c) => ProviderScope(
      overrides: [licensingControllerProvider.overrideWith((ref) => c)],
      child: MaterialApp(
        theme: ThemeData(extensions: [AppPalette.midnight]),
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {}, child: const Text('open')),
        )),
      ),
    );

void main() {
  testWidgets('shows the remaining free-export count and both actions',
      (tester) async {
    final c = _FakeController();
    await tester.pumpWidget(_host(c));
    final ctx = tester.element(find.text('open'));
    // ignore: unawaited_futures
    ExportNudgeDialog.show(ctx, remaining: 2);
    await tester.pumpAndSettle();

    expect(find.textContaining('2 free exports left'), findsOneWidget);
    expect(find.text('See plans'), findsOneWidget);
    expect(find.text('Maybe later'), findsOneWidget);
  });

  testWidgets('singularizes the count when one export remains', (tester) async {
    final c = _FakeController();
    await tester.pumpWidget(_host(c));
    final ctx = tester.element(find.text('open'));
    // ignore: unawaited_futures
    ExportNudgeDialog.show(ctx, remaining: 1);
    await tester.pumpAndSettle();
    expect(find.textContaining('1 free export left'), findsOneWidget);
  });

  testWidgets('See plans opens the purchase flow and dismisses',
      (tester) async {
    final c = _FakeController();
    await tester.pumpWidget(_host(c));
    final ctx = tester.element(find.text('open'));
    // ignore: unawaited_futures
    ExportNudgeDialog.show(ctx, remaining: 2);
    await tester.pumpAndSettle();

    await tester.tap(find.text('See plans'));
    await tester.pumpAndSettle();
    expect(c.unlockCalls, 1);
    expect(find.text('See plans'), findsNothing); // dialog dismissed
  });

  testWidgets('Maybe later dismisses without starting a purchase',
      (tester) async {
    final c = _FakeController();
    await tester.pumpWidget(_host(c));
    final ctx = tester.element(find.text('open'));
    // ignore: unawaited_futures
    ExportNudgeDialog.show(ctx, remaining: 2);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Maybe later'));
    await tester.pumpAndSettle();
    expect(c.unlockCalls, 0);
    expect(find.text('Maybe later'), findsNothing);
  });
}
