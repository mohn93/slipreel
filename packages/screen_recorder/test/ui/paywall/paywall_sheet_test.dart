import 'dart:async';

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
  bool throwOnUnlock = false;
  bool unlockReturns = true;
  // When set, unlockExport awaits this gate — lets a test hold the action
  // in-flight to assert the busy/spinner state, then release it.
  Completer<bool>? unlockGate;
  @override
  Future<bool> unlockExport() async {
    if (throwOnUnlock) throw Exception('no hw id');
    unlockCalls++;
    if (unlockGate != null) return unlockGate!.future;
    return unlockReturns;
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

  testWidgets('a throwing unlock does not crash the sheet', (tester) async {
    final c = _FakeController()..throwOnUnlock = true;
    await tester.pumpWidget(_host(c, onOpen: () {}));
    final ctx = tester.element(find.text('open'));
    // ignore: unawaited_futures
    PaywallSheet.show(ctx, reason: PaywallReason.needsPurchase);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlock export'));
    await tester.pump(); // run the async catch
    // Drain AppAlerts' auto-dismiss timer (6s for errors; no overlay is
    // attached in this test host, so nothing else fires it) so the test
    // doesn't end with a pending Timer.
    await tester.pump(const Duration(seconds: 7));
    expect(tester.takeException(), isNull); // the throw was caught, not propagated
  });

  testWidgets('subscriptionLapsed shows Continue and calls unlockExport',
      (tester) async {
    final c = _FakeController();
    await tester.pumpWidget(_host(c, onOpen: () {}));
    final ctx = tester.element(find.text('open'));
    // ignore: unawaited_futures
    PaywallSheet.show(ctx, reason: PaywallReason.subscriptionLapsed);
    await tester.pumpAndSettle();

    // The primary CTA reads "Continue" for a lapsed subscription, not "Unlock".
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Unlock export'), findsNothing);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(c.unlockCalls, 1);
  });

  testWidgets('"Already purchased? Sign in" calls openSignIn', (tester) async {
    final c = _FakeController();
    await tester.pumpWidget(_host(c, onOpen: () {}));
    final ctx = tester.element(find.text('open'));
    // ignore: unawaited_futures
    PaywallSheet.show(ctx, reason: PaywallReason.needsPurchase);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Already purchased? Sign in'));
    await tester.pump();
    expect(c.signInCalls, 1);
    expect(c.unlockCalls, 0);
  });

  testWidgets('unlock returning false keeps the sheet open (browser did not open)',
      (tester) async {
    final c = _FakeController()..unlockReturns = false;
    bool? result;
    await tester.pumpWidget(_host(c, onOpen: () {}));
    final ctx = tester.element(find.text('open'));
    unawaited(PaywallSheet.show(ctx, reason: PaywallReason.needsPurchase)
        .then((r) => result = r));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Unlock export'));
    await tester.pump(); // run the async result handling
    // Drain AppAlerts' error auto-dismiss timer (no overlay in this host).
    await tester.pump(const Duration(seconds: 7));
    expect(tester.takeException(), isNull);
    // Sheet stays open, not auto-dismissed, so the user can retry.
    expect(find.text('Unlock export'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('shows a spinner and disables the button while the action is in flight',
      (tester) async {
    final c = _FakeController()..unlockGate = Completer<bool>();
    await tester.pumpWidget(_host(c, onOpen: () {}));
    final ctx = tester.element(find.text('open'));
    // ignore: unawaited_futures
    PaywallSheet.show(ctx, reason: PaywallReason.needsPurchase);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Unlock export'));
    await tester.pump(); // enter the busy state (gate not yet completed)

    // Spinner is up; the label is gone and the button is disabled.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Unlock export'), findsNothing);
    final btn = tester.widget<ElevatedButton>(find.ancestor(
        of: find.byType(CircularProgressIndicator),
        matching: find.byType(ElevatedButton)));
    expect(btn.onPressed, isNull);

    // Release the action: spinner clears, label returns.
    c.unlockGate!.complete(false);
    await tester.pump(const Duration(seconds: 7)); // also drains the error timer
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Unlock export'), findsOneWidget);
  });
}
