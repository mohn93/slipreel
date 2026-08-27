import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/licensing/export_gate.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/ui/paywall/paywall_sheet.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

// A StateNotifier we can drive from the test, standing in for LicensingController.
class _FakeController extends StateNotifier<EntitlementState>
    implements LicensingController {
  _FakeController() : super(const EntitlementSignedOut());
  int unlockCalls = 0;
  int signInCalls = 0;
  @override
  Future<bool> unlockExport() async {
    unlockCalls++;
    return true;
  }

  @override
  Future<bool> openSignIn() async {
    signInCalls++;
    return true;
  }

  void grantEntitlement() {
    state = EntitlementLoaded(EntitlementClaims(
      sub: 'usr_1',
      plan: 'subscription',
      exportEntitled: true,
      status: 'active',
      updatesUntil: null,
      deviceId: 'dev_1',
      seatLimit: 2,
      issuedAt: DateTime.utc(2026, 1, 1),
      expiresAt: DateTime.utc(2030, 1, 1),
    ));
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget _host(_FakeController c, {required VoidCallback onOpen}) {
  return ProviderScope(
    overrides: [licensingControllerProvider.overrideWith((ref) => c)],
    child: MaterialApp(
      theme: ThemeData(extensions: [AppPalette.midnight]),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: onOpen,
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders needsPurchase and Unlock calls unlockExport',
      (tester) async {
    final c = _FakeController();
    bool? result;
    await tester.pumpWidget(_host(c, onOpen: () {}));
    // Open the sheet imperatively so we control the reason.
    final ctx = tester.element(find.text('open'));
    // ignore: unawaited_futures
    PaywallSheet.show(ctx, reason: PaywallReason.needsPurchase).then((r) => result = r);
    await tester.pumpAndSettle();

    expect(find.text('Unlock export'), findsOneWidget);
    await tester.tap(find.text('Unlock export'));
    await tester.pump();
    expect(c.unlockCalls, 1);

    // Simulate the deep link landing: entitlement flips -> sheet auto-dismisses true.
    c.grantEntitlement();
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.text('Unlock export'), findsNothing);
  });

  testWidgets('updateCeiling shows the renew message', (tester) async {
    final c = _FakeController();
    await tester.pumpWidget(_host(c, onOpen: () {}));
    final ctx = tester.element(find.text('open'));
    // ignore: unawaited_futures
    PaywallSheet.show(ctx, reason: PaywallReason.updateCeiling);
    await tester.pumpAndSettle();
    expect(find.textContaining('update'), findsWidgets);
  });
}
