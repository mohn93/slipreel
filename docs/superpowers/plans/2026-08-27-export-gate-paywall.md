# Export Gate + Paywall UI (Phase 6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate export behind the entitlement token: when the user is not entitled, block the export flow and present an in-app paywall sheet whose "Unlock export" button opens the browser purchase/sign-in flow; when the entitlement token deep-links back, the sheet auto-advances straight into export.

**Architecture:** A pure gate helper (`canExportNow` + `paywallReasonFor`) derives, from the Phase 5b `entitlementProvider` and the baked `buildReleaseDate`, whether export is allowed and — if not — which of three paywall messages to show. `PlaybackScreen._exportBody()` calls the gate before opening the export settings dialog; if blocked it shows `PaywallSheet` (a modal bottom sheet, mirroring the existing `PermissionDeniedSheet`) instead. The sheet is a `Consumer` that watches `entitlementProvider` and, the moment entitlement flips to allowed (the deep link from Phase 5b lands), auto-dismisses with a "proceed" result so export continues seamlessly. A defense-in-depth check inside `ExportController.run()` returns a new `ExportNotEntitled` outcome if entitlement is somehow absent at pipeline start, so no code path encodes unpaid.

**Tech Stack:** Flutter/Dart, Riverpod (`ConsumerStatefulWidget` / `ref.watch` / `ref.read(...).notifier`), the existing `AppPalette` (`context.palette.<role>`) + `AppAlerts` conventions, `showModalBottomSheet`.

**Spec:** docs/superpowers/specs/2026-08-26-stripe-licensing-design.md (§2 entitlement truth table, §9 export gate + paywall UI, §11 Sparkle/version-ceiling nuance).

## Global Constraints

- Package under work: `packages/screen_recorder` (Dart package `screen_recorder`). Run all Flutter commands with `fvm flutter` from `packages/screen_recorder`.
- **NEVER run `dart format`** — the repo's pinned formatter reflows unrelated lines. `fvm flutter analyze` is the style/lint gate. Match surrounding style by hand.
- No emoji in commit messages, code comments, or docs. Succinct.
- Stage only files you changed (`git add <path>` per file). Never `git add -A` / `git add .`. Other agents may share the checkout (untracked `.claude/launch.json`, `demo-uis/` are theirs — leave them).
- Branch: `feat/stripe-licensing` (already checked out). Do NOT open a PR or merge; commits accumulate on the branch (PR #65 tracks it).
- Phase 5b interfaces this plan consumes (do NOT change their signatures):
  - `entitlementProvider` = `Provider<EntitlementState>` (lib/licensing/licensing_controller.dart).
  - `licensingControllerProvider` = `StateNotifierProvider<LicensingController, EntitlementState>`; the controller exposes `Future<bool> unlockExport()`, `Future<void> signOut()`, `Future<void> refreshNow()`.
  - Sealed `EntitlementState` = `EntitlementLoading` | `EntitlementSignedOut` | `EntitlementLoaded(EntitlementClaims claims)` (lib/licensing/entitlement.dart).
  - `bool canExport(EntitlementClaims? claims, {required DateTime appReleaseDate, DateTime? now})` — nullable claims; returns false on null (lib/licensing/entitlement.dart).
  - `EntitlementClaims` fields: `plan` (String `'subscription'|'onetime'|'free'`), `status` (String `'active'|'grace'|'canceled'`), `updatesUntil` (DateTime?), `exportEntitled` (bool), etc.
  - `final DateTime buildReleaseDate` (lib/licensing/build_release_date.g.dart) — the value to pass as `appReleaseDate`.
  - `AuthStateStore` (lib/licensing/auth_state_store.dart): `Future<String> begin()`, `Uri pricingUrl({required String deviceFingerprint, required String state})`, uses `LicensingConfig.siteBaseResolved`.
- UX decisions (locked with the user):
  - **Minimal in-app pricing:** the sheet describes the two plan types qualitatively (subscription vs one-time perpetual + 1 year of updates); it shows NO hard prices — the real Stripe prices live on the web pricing page. Do not hardcode dollar amounts.
  - **Auto-advance:** after "Unlock export", when `entitlementProvider` flips to entitled, the sheet dismisses itself and export proceeds automatically.

## Design tokens & patterns (from the codebase, verbatim)

- Palette read: `import 'package:screen_recorder/ui/theme/app_palette_context.dart';` then `context.palette.<role>`. Roles: `appBackground`, `surfaceLow`, `surfaceElevated`, `surfaceCard`, `dividerSubtle`, `dividerStrong`, `accent`, `accentMuted`, `textPrimary`, `textSecondary`.
- Alerts: `import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';` then `AppAlerts.error(msg)` / `.success` / `.warning` / `.info` (BuildContext-free statics).
- Modal sheet template: `lib/ui/widgets/permission_denied_sheet.dart` — a `static Future<T?> show(BuildContext, ...)` wrapper around `showModalBottomSheet(context:, isDismissible:, showDragHandle:, builder:)`.
- Riverpod: `ConsumerStatefulWidget`/`ConsumerState`; watch reactively with `ref.watch(provider)`; call methods via `ref.read(licensingControllerProvider.notifier).unlockExport()`.

---

## File Structure

- `packages/screen_recorder/lib/licensing/export_gate.dart` — CREATE. `canExportNow`, `PaywallReason`, `paywallReasonFor` (pure logic).
- `packages/screen_recorder/lib/licensing/auth_state_store.dart` — MODIFY. Add `loginUrl(...)`.
- `packages/screen_recorder/lib/licensing/licensing_controller.dart` — MODIFY. Add `openSignIn()`.
- `packages/screen_recorder/lib/ui/paywall/paywall_sheet.dart` — CREATE. `PaywallSheet.show(...)` + the sheet body widget.
- `packages/screen_recorder/lib/ui/screens/playback/export_controller.dart` — MODIFY. Add `ExportNotEntitled` outcome + injected `isExportEntitled` check.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — MODIFY. Gate `_exportBody()`; pass `isExportEntitled` to `ExportController`; handle `ExportNotEntitled` in the outcome switch.
- Tests under `packages/screen_recorder/test/licensing/` and `packages/screen_recorder/test/ui/paywall/`.

---

## Task 1: Export gate logic (`canExportNow` + paywall reason)

**Files:**
- Create: `packages/screen_recorder/lib/licensing/export_gate.dart`
- Test: `packages/screen_recorder/test/licensing/export_gate_test.dart`

**Interfaces:**
- Consumes: `EntitlementState`, `EntitlementLoaded`, `EntitlementClaims`, `canExport` (entitlement.dart).
- Produces:
  - `bool canExportNow(EntitlementState state, {required DateTime appReleaseDate, DateTime? now})` — unwraps loaded claims (or null) and delegates to `canExport`.
  - `enum PaywallReason { needsPurchase, subscriptionLapsed, updateCeiling }`.
  - `PaywallReason? paywallReasonFor(EntitlementState state, {required DateTime appReleaseDate, DateTime? now})` — null when export is allowed; otherwise the message variant.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/licensing/export_gate_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/licensing/export_gate.dart';

EntitlementClaims _claims({
  required String plan,
  required String status,
  DateTime? updatesUntil,
  bool exportEntitled = true,
}) =>
    EntitlementClaims(
      sub: 'usr_1',
      plan: plan,
      exportEntitled: exportEntitled,
      status: status,
      updatesUntil: updatesUntil,
      deviceId: 'dev_1',
      seatLimit: 2,
      issuedAt: DateTime.utc(2026, 1, 1),
      expiresAt: DateTime.utc(2030, 1, 1),
    );

void main() {
  final release = DateTime.utc(2026, 8, 27);

  group('canExportNow', () {
    test('loading -> false', () {
      expect(canExportNow(const EntitlementLoading(), appReleaseDate: release),
          isFalse);
    });
    test('signed out -> false', () {
      expect(canExportNow(const EntitlementSignedOut(), appReleaseDate: release),
          isFalse);
    });
    test('active subscription -> true', () {
      final s = EntitlementLoaded(_claims(plan: 'subscription', status: 'active'));
      expect(canExportNow(s, appReleaseDate: release), isTrue);
    });
    test('one-time within ceiling -> true', () {
      final s = EntitlementLoaded(_claims(
          plan: 'onetime',
          status: 'active',
          updatesUntil: DateTime.utc(2027, 1, 1)));
      expect(canExportNow(s, appReleaseDate: release), isTrue);
    });
  });

  group('paywallReasonFor', () {
    test('entitled -> null (no paywall)', () {
      final s = EntitlementLoaded(_claims(plan: 'subscription', status: 'active'));
      expect(paywallReasonFor(s, appReleaseDate: release), isNull);
    });
    test('signed out -> needsPurchase', () {
      expect(paywallReasonFor(const EntitlementSignedOut(), appReleaseDate: release),
          PaywallReason.needsPurchase);
    });
    test('loading -> needsPurchase', () {
      expect(paywallReasonFor(const EntitlementLoading(), appReleaseDate: release),
          PaywallReason.needsPurchase);
    });
    test('canceled subscription -> subscriptionLapsed', () {
      final s =
          EntitlementLoaded(_claims(plan: 'subscription', status: 'canceled'));
      expect(paywallReasonFor(s, appReleaseDate: release),
          PaywallReason.subscriptionLapsed);
    });
    test('one-time past update ceiling -> updateCeiling', () {
      final s = EntitlementLoaded(_claims(
          plan: 'onetime',
          status: 'active',
          updatesUntil: DateTime.utc(2026, 1, 1))); // before release
      expect(paywallReasonFor(s, appReleaseDate: release),
          PaywallReason.updateCeiling);
    });
    test('free plan -> needsPurchase', () {
      final s = EntitlementLoaded(
          _claims(plan: 'free', status: 'active', exportEntitled: false));
      expect(paywallReasonFor(s, appReleaseDate: release),
          PaywallReason.needsPurchase);
    });
  });
}
```

- [ ] **Step 2: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/export_gate_test.dart`
Expected: FAIL — `export_gate.dart` missing.

- [ ] **Step 3: Implement**

Create `packages/screen_recorder/lib/licensing/export_gate.dart`:

```dart
import 'entitlement.dart';
import 'entitlement_claims.dart';

/// The three reasons export can be blocked, each mapping to a distinct paywall
/// message (spec §2). null (from [paywallReasonFor]) means export is allowed.
enum PaywallReason {
  /// No purchase on this account (free / signed out / loading). Show plans.
  needsPurchase,

  /// A subscription that is no longer active or in grace. Prompt to resubscribe.
  subscriptionLapsed,

  /// A one-time license whose update window ended before this build's release
  /// date (spec §2/§11 perpetual-fallback). Prompt to renew the update year.
  updateCeiling,
}

EntitlementClaims? _claimsOf(EntitlementState state) =>
    state is EntitlementLoaded ? state.claims : null;

/// Whether export is currently allowed for [state], per the spec §2 rules.
/// Loading/signed-out both resolve to false (fail-closed).
bool canExportNow(
  EntitlementState state, {
  required DateTime appReleaseDate,
  DateTime? now,
}) {
  return canExport(_claimsOf(state), appReleaseDate: appReleaseDate, now: now);
}

/// Which paywall message to show, or null when export is allowed.
PaywallReason? paywallReasonFor(
  EntitlementState state, {
  required DateTime appReleaseDate,
  DateTime? now,
}) {
  if (canExportNow(state, appReleaseDate: appReleaseDate, now: now)) {
    return null;
  }
  final claims = _claimsOf(state);
  if (claims != null && claims.plan == 'onetime' &&
      claims.updatesUntil != null &&
      appReleaseDate.isAfter(claims.updatesUntil!)) {
    return PaywallReason.updateCeiling;
  }
  if (claims != null && claims.plan == 'subscription') {
    return PaywallReason.subscriptionLapsed;
  }
  return PaywallReason.needsPurchase;
}
```

- [ ] **Step 4: Run — verify pass**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/export_gate_test.dart`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/licensing/export_gate.dart packages/screen_recorder/test/licensing/export_gate_test.dart
git commit -m "feat(app): export gate logic + paywall reason"
```

---

## Task 2: Sign-in browser handoff (`loginUrl` + `openSignIn`)

**Files:**
- Modify: `packages/screen_recorder/lib/licensing/auth_state_store.dart`
- Modify: `packages/screen_recorder/lib/licensing/licensing_controller.dart`
- Test: `packages/screen_recorder/test/licensing/auth_state_store_test.dart` (add one test)
- Test: `packages/screen_recorder/test/licensing/licensing_controller_activation_test.dart` (add one test)

**Interfaces:**
- Consumes: existing `AuthStateStore.begin()`, `DeviceFingerprint`, the controller's `_openUrl`.
- Produces:
  - `Uri AuthStateStore.loginUrl({required String deviceFingerprint, required String state})` — `${siteBase}/login?device=<fp>&state=<nonce>`.
  - `Future<bool> LicensingController.openSignIn()` — same shape as `unlockExport()` but opens the login page (for returning/already-purchased users). Returns the opener's bool.

- [ ] **Step 1: Add the failing `loginUrl` test**

In `packages/screen_recorder/test/licensing/auth_state_store_test.dart`, add:

```dart
  test('loginUrl carries device + state', () {
    final store = AuthStateStore(InMemorySecureKV());
    final url = store.loginUrl(deviceFingerprint: 'fp_abc', state: 'n1');
    expect(url.path, '/login');
    expect(url.queryParameters['device'], 'fp_abc');
    expect(url.queryParameters['state'], 'n1');
  });
```

- [ ] **Step 2: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/auth_state_store_test.dart`
Expected: FAIL — `loginUrl` not defined.

- [ ] **Step 3: Implement `loginUrl`**

In `packages/screen_recorder/lib/licensing/auth_state_store.dart`, add this method next to `pricingUrl` (reuse the same builder shape):

```dart
  /// `${siteBase}/login?device=<fp>&state=<nonce>` — the sign-in page for a
  /// returning/already-purchased user (vs [pricingUrl] which shows plans).
  Uri loginUrl({
    required String deviceFingerprint,
    required String state,
  }) {
    final base = Uri.parse(LicensingConfig.siteBaseResolved);
    return base.replace(
      path: '/login',
      queryParameters: {'device': deviceFingerprint, 'state': state},
    );
  }
```

- [ ] **Step 4: Run — verify pass**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/auth_state_store_test.dart`
Expected: PASS.

- [ ] **Step 5: Add the failing `openSignIn` test**

In `packages/screen_recorder/test/licensing/licensing_controller_activation_test.dart`, add (mirroring the existing `unlockExport` test — it uses the mocked `slipreel/device` channel already set up in that file's `main()`):

```dart
  test('openSignIn opens the login url with device + state', () async {
    messenger.setMockMethodCallHandler(
        channel, (call) async => 'HW-UUID-123');
    Uri? opened;
    final auth = AuthStateStore(InMemorySecureKV());
    final c = LicensingController(
      store: InMemoryLicenseStore(),
      verifier: _FakeVerifier(const {}),
      api: LicensingApi(baseUrl: 'https://x.test'),
      authState: auth,
      openUrl: (u) async {
        opened = u;
        return true;
      },
    );
    final ok = await c.openSignIn();
    expect(ok, isTrue);
    expect(opened!.path, '/login');
    expect(opened!.queryParameters['device'], isNotEmpty);
    expect(await auth.matches(opened!.queryParameters['state']!), isTrue);
  });
```

- [ ] **Step 6: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/licensing_controller_activation_test.dart`
Expected: FAIL — `openSignIn` not defined.

- [ ] **Step 7: Implement `openSignIn`**

In `packages/screen_recorder/lib/licensing/licensing_controller.dart`, add next to `unlockExport()`:

```dart
  /// Like [unlockExport] but opens the sign-in page instead of the plans page,
  /// for a user who has already purchased (another device, or after sign-out).
  Future<bool> openSignIn() async {
    final fp = await _fingerprint.compute();
    final nonce = await _authState.begin();
    final url = _authState.loginUrl(deviceFingerprint: fp, state: nonce);
    return _openUrl(url);
  }
```

- [ ] **Step 8: Run — verify pass + whole licensing suite**

Run: `cd packages/screen_recorder && fvm flutter test test/licensing/`
Expected: all PASS. Then `fvm flutter analyze` — clean.

- [ ] **Step 9: Commit**

```bash
git add packages/screen_recorder/lib/licensing/auth_state_store.dart packages/screen_recorder/lib/licensing/licensing_controller.dart packages/screen_recorder/test/licensing/auth_state_store_test.dart packages/screen_recorder/test/licensing/licensing_controller_activation_test.dart
git commit -m "feat(app): sign-in browser handoff (loginUrl + openSignIn)"
```

---

## Task 3: Paywall sheet UI

**Files:**
- Create: `packages/screen_recorder/lib/ui/paywall/paywall_sheet.dart`
- Test: `packages/screen_recorder/test/ui/paywall/paywall_sheet_test.dart`

**Interfaces:**
- Consumes: `PaywallReason` (export_gate.dart), `canExportNow`, `entitlementProvider`, `licensingControllerProvider`, `buildReleaseDate`, `AppPalette`, `AppAlerts`.
- Produces:
  - `class PaywallSheet` with `static Future<bool> show(BuildContext context, {required PaywallReason reason})` — returns `true` if the user became entitled while the sheet was open (caller should proceed to export), `false` if dismissed without entitlement.
  - The sheet body is a `ConsumerStatefulWidget` that watches `entitlementProvider`; when `canExportNow` becomes true it pops the sheet with `true`.

- [ ] **Step 1: Write the failing widget test**

Create `packages/screen_recorder/test/ui/paywall/paywall_sheet_test.dart`. It overrides `licensingControllerProvider` with a controllable fake so it can (a) assert the primary button calls `unlockExport`, and (b) flip entitlement and assert auto-dismiss:

```dart
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
    PaywallSheet.show(ctx, reason: PaywallReason.needsPurchase)
        .then((r) => result = r);
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
    PaywallSheet.show(ctx, reason: PaywallReason.updateCeiling);
    await tester.pumpAndSettle();
    expect(find.textContaining('update'), findsWidgets);
  });
}
```

- [ ] **Step 2: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/paywall/paywall_sheet_test.dart`
Expected: FAIL — `paywall_sheet.dart` missing.

- [ ] **Step 3: Implement the sheet**

Create `packages/screen_recorder/lib/ui/paywall/paywall_sheet.dart`. Keep copy minimal and price-free (per the locked UX). Use `context.palette` tokens and match the `PermissionDeniedSheet.show` wrapper shape:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/licensing/build_release_date.g.dart';
import 'package:screen_recorder/licensing/export_gate.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// The export paywall. Blocks export for unentitled users and starts the
/// browser purchase/sign-in flow. Watches [entitlementProvider]; when export
/// becomes allowed (the Phase 5b deep link lands) it auto-dismisses with true
/// so the caller proceeds straight into export.
class PaywallSheet {
  const PaywallSheet._();

  /// Returns true if the user became entitled while the sheet was open.
  static Future<bool> show(
    BuildContext context, {
    required PaywallReason reason,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: true,
      showDragHandle: true,
      backgroundColor: context.palette.surfaceElevated,
      builder: (_) => _PaywallBody(reason: reason),
    );
    return result ?? false;
  }
}

class _PaywallBody extends ConsumerStatefulWidget {
  const _PaywallBody({required this.reason});
  final PaywallReason reason;

  @override
  ConsumerState<_PaywallBody> createState() => _PaywallBodyState();
}

class _PaywallBodyState extends ConsumerState<_PaywallBody> {
  bool _busy = false;

  ({String title, String body}) _copy(PaywallReason reason) {
    switch (reason) {
      case PaywallReason.needsPurchase:
        return (
          title: 'Unlock export',
          body: 'Recording and editing are free. Exporting is a paid feature. '
              'Choose a subscription or a one-time purchase (perpetual export '
              'plus one year of updates) on the next screen.',
        );
      case PaywallReason.subscriptionLapsed:
        return (
          title: 'Your subscription has lapsed',
          body: 'Export is locked until your subscription is active again. '
              'Manage or renew it on the next screen.',
        );
      case PaywallReason.updateCeiling:
        return (
          title: 'Renew your update year',
          body: 'Your one-time license covers versions released within your '
              'update window. This build is newer, so export is locked here. '
              'Renew another year of updates to export on the latest version '
              'your earlier build still exports as before.',
        );
    }
  }

  Future<void> _run(Future<bool> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await action();
      if (!ok && mounted) {
        AppAlerts.error('Could not open the browser. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Auto-advance: the instant export becomes allowed, close with success.
    ref.listen<EntitlementState>(entitlementProvider, (_, next) {
      if (canExportNow(next, appReleaseDate: buildReleaseDate)) {
        Navigator.of(context).maybePop(true);
      }
    });

    final palette = context.palette;
    final copy = _copy(widget.reason);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(copy.title,
                style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Text(copy.body,
                style: TextStyle(color: palette.textSecondary, height: 1.4)),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      ref.read(licensingControllerProvider.notifier).unlockExport),
              style: ElevatedButton.styleFrom(
                  backgroundColor: palette.accent,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: Text(widget.reason == PaywallReason.needsPurchase
                  ? 'Unlock export'
                  : 'Continue'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      ref.read(licensingControllerProvider.notifier).openSignIn),
              child: Text('Already purchased? Sign in',
                  style: TextStyle(color: palette.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run — verify pass**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/paywall/paywall_sheet_test.dart`
Expected: PASS (2 tests). If the auto-dismiss test flakes on timing, ensure the `ref.listen` fires on state change (it does — `_FakeController.grantEntitlement()` sets state, which notifies the overridden provider).

- [ ] **Step 5: Analyze + commit**

Run: `cd packages/screen_recorder && fvm flutter analyze lib/ui/paywall test/ui/paywall` — expect clean.

```bash
git add packages/screen_recorder/lib/ui/paywall/paywall_sheet.dart packages/screen_recorder/test/ui/paywall/paywall_sheet_test.dart
git commit -m "feat(app): export paywall sheet (minimal pricing, auto-advance)"
```

---

## Task 4: Defense-in-depth in ExportController

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback/export_controller.dart`
- Test: `packages/screen_recorder/test/ui/screens/playback/export_controller_entitlement_test.dart`

**Interfaces:**
- Consumes: nothing new (a plain injected callback).
- Produces:
  - New sealed variant `class ExportNotEntitled extends ExportOutcome { const ExportNotEntitled(); }`.
  - `ExportController` constructor gains `required bool Function() isExportEntitled`.
  - `run()` returns `const ExportNotEntitled()` immediately (before touching the pipeline) when `isExportEntitled()` is false.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/ui/screens/playback/export_controller_entitlement_test.dart`. Inspect the real `ExportController` constructor first (it takes `required this.runPipeline`); pass a `runPipeline` that throws if called, so the test proves the guard short-circuits before the pipeline:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/screens/playback/export_controller.dart';
// Import whatever types runPipeline/DestinationHandler need; see the real file.

void main() {
  test('run returns ExportNotEntitled without invoking the pipeline', () async {
    var pipelineCalled = false;
    final controller = ExportController(
      isExportEntitled: () => false,
      runPipeline: (/* real signature */) async {
        pipelineCalled = true;
        throw StateError('pipeline must not run when unentitled');
      },
    );
    final outcome = await controller.run(
      outputPath: '/tmp/out.mp4',
      handler: /* a minimal fake or the real handler as the file expects */,
      onProgress: (_) {},
    );
    expect(outcome, isA<ExportNotEntitled>());
    expect(pipelineCalled, isFalse);
  });
}
```

NOTE to implementer: the exact `runPipeline` closure signature and the `DestinationHandler` argument are defined in `export_controller.dart` / the playback pipeline types — read them and fill the placeholders so the test compiles. Keep the fake minimal. If constructing a real `DestinationHandler` is heavy, the guard returns before `handler` is used, so a trivial stub/null-safe fake is fine; match what the constructor and `run()` actually require to compile.

- [ ] **Step 2: Run — verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/screens/playback/export_controller_entitlement_test.dart`
Expected: FAIL — `isExportEntitled` param and `ExportNotEntitled` don't exist.

- [ ] **Step 3: Implement**

In `packages/screen_recorder/lib/ui/screens/playback/export_controller.dart`:

Add the outcome variant to the sealed hierarchy (next to `ExportCancelled`):

```dart
/// Export was attempted without an active entitlement. A UI-level gate should
/// have caught this first; this is the pipeline's fail-closed backstop so no
/// path encodes unpaid.
class ExportNotEntitled extends ExportOutcome {
  const ExportNotEntitled();
}
```

Add the constructor field (keep the existing `runPipeline`):

```dart
  ExportController({
    required this.runPipeline,
    required this.isExportEntitled,
  });

  final bool Function() isExportEntitled;
```

At the very top of `run()` (before any pipeline work):

```dart
    if (!isExportEntitled()) {
      return const ExportNotEntitled();
    }
```

- [ ] **Step 4: Run — verify pass**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/screens/playback/export_controller_entitlement_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback/export_controller.dart packages/screen_recorder/test/ui/screens/playback/export_controller_entitlement_test.dart
git commit -m "feat(app): ExportController entitlement backstop (ExportNotEntitled)"
```

---

## Task 5: Wire the gate into the export flow

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

**Interfaces:**
- Consumes: `canExportNow`, `paywallReasonFor`, `PaywallSheet`, `buildReleaseDate`, `entitlementProvider` (via `ref`), the new `ExportController.isExportEntitled` param and `ExportNotEntitled` outcome.
- Produces: no new public interface — behavioral change to `_exportBody()` and the outcome switch.

- [ ] **Step 1: Add imports**

In `packages/screen_recorder/lib/ui/screens/playback_screen.dart`, add (match the file's existing import style — package imports):

```dart
import 'package:screen_recorder/licensing/build_release_date.g.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/export_gate.dart';
import 'package:screen_recorder/ui/paywall/paywall_sheet.dart';
```

- [ ] **Step 2: Gate `_exportBody()` before the export dialog**

Locate the point in `_exportBody()` right after the probe/setup succeeds and just before `settings = await showDialog<ExportSettings>(...)` (around line 1861, after the `if (!mounted) return;` at ~1859). Insert:

```dart
      // Export gate (spec §2/§9). If not entitled, show the paywall instead of
      // the export dialog. The sheet auto-advances (returns true) if the user
      // becomes entitled via the browser flow while it's open.
      final entitlementState = ref.read(entitlementProvider);
      if (!canExportNow(entitlementState, appReleaseDate: buildReleaseDate)) {
        final reason =
            paywallReasonFor(entitlementState, appReleaseDate: buildReleaseDate)!;
        final becameEntitled = await PaywallSheet.show(context, reason: reason);
        if (!becameEntitled || !mounted) return;
        // fall through to the export dialog now that export is unlocked
      }
```

- [ ] **Step 3: Pass the entitlement backstop to `ExportController`**

Find where `ExportController(...)` is constructed (around line 2001). Add the callback argument:

```dart
        isExportEntitled: () =>
            canExportNow(ref.read(entitlementProvider), appReleaseDate: buildReleaseDate),
```

- [ ] **Step 4: Handle `ExportNotEntitled` in the outcome switch**

Find the `switch` over the `ExportOutcome` (around line 2039, after the progress dialog is popped). Add a case:

```dart
      case ExportNotEntitled():
        AppAlerts.error('Export needs an active license.');
```

(The normal path never reaches this — Step 2 gates first — so a terse alert is the correct backstop. `AppAlerts` is already imported in this file.)

- [ ] **Step 5: Analyze + build**

Run: `cd packages/screen_recorder && fvm flutter analyze` — expect clean (the sealed `ExportOutcome` switch is now exhaustive with the new case; if analyze complains the switch is non-exhaustive elsewhere, add the same case there).

Run: `cd packages/screen_recorder && fvm flutter build macos --debug` — expect a green build.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(app): gate export behind entitlement + paywall"
```

---

## Task 6: Full verification + live paywall smoke test

**Files:** none (verification only).

- [ ] **Step 1: Full package test suite**

Run: `cd packages/screen_recorder && fvm flutter test`
Expected: all pass (the new gate/paywall/controller tests + the existing suite; nothing regressed).

- [ ] **Step 2: Analyze**

Run: `cd packages/screen_recorder && fvm flutter analyze`
Expected: No issues found.

- [ ] **Step 3: Live smoke test (coordinator verifies)**

Launch the built app signed-out (no cached token). Open a recording in the editor and click Export. Expected: the **paywall sheet appears** (not the export settings dialog), showing the `needsPurchase` copy. Click "Unlock export" and confirm the browser opens to the pricing page (`${site}/pricing?device=...&state=...`). Full auto-advance (the token deep-linking back and export proceeding) requires a live server-signed token and is a **Phase 7** end-to-end step — here, verify up to: paywall shown, browser opens with the correct URL, and the app does not crash. Capture a screenshot of the paywall as proof.

- [ ] **Step 4: No commit** (verification only). Record results in the ledger.

---

## Self-Review Notes (author checklist — resolved)

- **Spec §9 coverage:** gate at `_exportBody()` before `ExportDialog` (Task 5); defense-in-depth in `ExportController.run()` (Task 4); paywall UI in `lib/ui/paywall/` with two plan types + "Unlock export" + "Sign in" (Tasks 2, 3); uses `AppPalette` + `AppAlerts`. Covered.
- **Spec §2 coverage:** `canExportNow` delegates to the Phase 5a `canExport` truth table; `paywallReasonFor` distinguishes needsPurchase / subscriptionLapsed / updateCeiling (Task 1). The one-time version-ceiling soft-lock (spec §11) is the `updateCeiling` variant.
- **Locked UX:** minimal pricing (no hardcoded amounts — copy points to the web page) and auto-advance (the sheet's `ref.listen` on `entitlementProvider` pops `true` when export becomes allowed). Both honored in Task 3.
- **Type consistency:** `canExportNow(EntitlementState, {appReleaseDate, now})`, `paywallReasonFor(...) -> PaywallReason?`, `PaywallSheet.show(context, {reason}) -> Future<bool>`, `ExportController({runPipeline, isExportEntitled})`, `ExportNotEntitled` — used identically across Tasks 1/3/4/5.
- **Deferred (not in this plan):** the live token round-trip / real auto-advance (Phase 7); an in-app account/manage screen (the web account page covers it); reconciling stale landing-page marketing pricing (tracked separately).
- **One detail to confirm during Task 4:** the exact `runPipeline` closure signature + `DestinationHandler` type in `export_controller.dart` — the implementer reads the real file and fills the test placeholders so it compiles; the guard returns before `handler`/`runPipeline` are used.
