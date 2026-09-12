import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/licensing/export_gate.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/store/app_store_client.dart';
import 'package:screen_recorder/store/native_account.dart';
import 'package:screen_recorder/store/store_paywall.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/desktop_dialog.dart';

class FakeStore extends AppStoreClient {
  int purchases = 0, restores = 0;
  String result = 'cancelled';
  bool unavailable = false;
  List<StoreProduct>? offerings;
  String? purchasedId;
  VoidCallback? onPurchased;
  Completer<List<StoreProduct>>? loading;
  @override
  Future<List<StoreProduct>> products() async {
    if (loading != null) return loading!.future;
    if (offerings != null) return offerings!;
    if (unavailable) throw Exception('offline');
    return const [
      StoreProduct('com.slipreel.store.yearly', 'Pro', '€79.99', 'year'),
      StoreProduct('com.slipreel.store.monthly', 'Pro', '€9.99', 'month'),
    ];
  }

  @override
  Future<String> purchase(String id, String appAccountToken) async {
    purchases++;
    purchasedId = id;
    if (result == 'purchased') onPurchased?.call();
    return result;
  }

  @override
  Future<void> restore() async {
    restores++;
  }
}

class FakeLicensing extends StateNotifier<EntitlementState>
    implements LicensingController {
  FakeLicensing(this.appStore) : super(const EntitlementAppStore());
  @override
  final FakeStore appStore;
  @override
  Future<void> refreshNow() async {}
  void setAccess(EntitlementState value) => state = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAccount extends NativeAccount {
  FakeAccount(super.licensing) {
    email = 'qa@example.com';
    appAccountToken = '11111111-1111-4111-8111-111111111111';
  }
  bool grantOnActivate = false, syncFailure = false;
  @override
  Future<void> load() async {}
  @override
  Future<void> activate() async {
    if (grantOnActivate) (licensing as FakeLicensing).setAccess(paid());
  }

  @override
  Future<void> syncPurchases() async {
    if (syncFailure) throw const AccountError('sync failed');
    (licensing as FakeLicensing).setAccess(paid());
  }
}

EntitlementAppStore paid() => EntitlementAppStore(
  productId: 'com.slipreel.store.yearly',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

Future<void> openPaywall(
  WidgetTester tester,
  FakeLicensing c,
  FakeAccount a, {
  PaywallReason reason = PaywallReason.needsPurchase,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        licensingControllerProvider.overrideWith((ref) => c),
        nativeAccountProvider.overrideWith((ref) => a),
      ],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(extensions: [AppPalette.midnight]),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDesktopDialog<bool>(
                context: context,
                builder: (_) => StorePaywall(reason: reason),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  // Optional local visual capture uses actual Flutter widgets and a supplied
  // system font. It never changes the shipped app or contacts payment services.
  testWidgets('visual preview capture', (tester) async {
    final directory = Platform.environment['SLIPREEL_UI_CAPTURE'];
    if (directory == null) return;
    final fontPath = Platform.environment['SLIPREEL_UI_FONT'];
    if (fontPath != null) {
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())),
        );
      await tester.runAsync(loader.load);
    }
    final iconPath = Platform.environment['SLIPREEL_UI_ICONS'];
    if (iconPath != null) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(File(iconPath).readAsBytesSync())),
        );
      await tester.runAsync(loader.load);
    }
    tester.view.physicalSize = const Size(800, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = FakeLicensing(
      FakeStore()
        ..offerings = const [
          StoreProduct(
            'com.slipreel.store.monthly',
            'Pro',
            '\$9.00',
            'month',
            priceValue: 9,
            currencyCode: 'USD',
          ),
          StoreProduct(
            'com.slipreel.store.yearly',
            'Pro',
            '\$79.00',
            'year',
            priceValue: 79,
            currencyCode: 'USD',
          ),
        ],
    );
    final a = FakeAccount(c);
    await openPaywall(tester, c, a);
    await expectLater(
      find
          .ancestor(
            of: find.byType(StorePaywall),
            matching: find.byType(RepaintBoundary),
          )
          .first,
      matchesGoldenFile('$directory/paywall.png'),
    );
  });
  testWidgets(
    'localized plans choose the exact yearly product and cancellation is recoverable',
    (tester) async {
      final c = FakeLicensing(FakeStore());
      final a = FakeAccount(c);
      await openPaywall(tester, c, a);
      expect(find.text('€79.99'), findsOneWidget);
      await tap(tester, 'Yearly');
      expect(
        find.text('€79.99 charged yearly. Renews every year.'),
        findsOneWidget,
      );
      await tap(tester, 'Unlock unlimited exports');
      expect(c.appStore.purchasedId, 'com.slipreel.store.yearly');
      expect(find.textContaining('Purchase cancelled.'), findsOneWidget);
      expect(find.text('Unlock unlimited exports'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('existing access discovered at sign in suppresses checkout', (
    tester,
  ) async {
    final c = FakeLicensing(FakeStore());
    final a = FakeAccount(c)..grantOnActivate = true;
    await openPaywall(tester, c, a);
    await tap(tester, 'Unlock unlimited exports');
    expect(c.appStore.purchases, 0);
    expect(find.byType(StorePaywall), findsNothing);
  });
  testWidgets(
    'pending approval keeps editing possible and later resumes the gate',
    (tester) async {
      final c = FakeLicensing(FakeStore()..result = 'pending');
      final a = FakeAccount(c);
      await openPaywall(tester, c, a);
      await tap(tester, 'Unlock unlimited exports');
      expect(
        find.textContaining('Waiting for purchase approval.'),
        findsOneWidget,
      );
      c.setAccess(paid());
      await tester.pumpAndSettle();
      expect(find.byType(StorePaywall), findsNothing);
    },
  );
  testWidgets('failed purchase is not described as cancellation', (
    tester,
  ) async {
    final c = FakeLicensing(FakeStore()..result = 'failed');
    await openPaywall(tester, c, FakeAccount(c));
    await tap(tester, 'Unlock unlimited exports');
    expect(find.textContaining('The purchase did not finish.'), findsOneWidget);
  });
  testWidgets('successful purchase completes the export gate', (tester) async {
    final c = FakeLicensing(FakeStore()..result = 'purchased');
    await openPaywall(tester, c, FakeAccount(c));
    await tap(tester, 'Unlock unlimited exports');
    expect(c.appStore.purchases, 1);
    expect(find.byType(StorePaywall), findsNothing);
  });
  testWidgets(
    'completed purchase with sync failure keeps local access available',
    (tester) async {
      final c = FakeLicensing(FakeStore()..result = 'purchased');
      c.appStore.onPurchased = () => c.setAccess(paid());
      await openPaywall(tester, c, FakeAccount(c)..syncFailure = true);
      await tap(tester, 'Unlock unlimited exports');
      expect(find.textContaining('Purchase complete.'), findsOneWidget);
      expect(find.text('Continue to export'), findsOneWidget);
      expect(find.text('Unlock unlimited exports'), findsNothing);
    },
  );
  testWidgets('unavailable products show retry without enabling checkout', (
    tester,
  ) async {
    final store = FakeStore()..unavailable = true;
    final c = FakeLicensing(store);
    await openPaywall(tester, c, FakeAccount(c));
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Unlock unlimited exports'),
          )
          .onPressed,
      isNull,
    );
    store.unavailable = false;
    await tap(tester, 'Retry loading plans');
    expect(find.text('€9.99'), findsOneWidget);
  });
  testWidgets(
    'license verification offers recovery rather than another purchase',
    (tester) async {
      final c = FakeLicensing(FakeStore());
      await openPaywall(
        tester,
        c,
        FakeAccount(c),
        reason: PaywallReason.licenseCheckRequired,
      );
      expect(find.text('Unlock unlimited exports'), findsNothing);
      await tap(tester, 'Verify existing access');
      expect(
        find.textContaining('Access could not be verified.'),
        findsOneWidget,
      );
      expect(c.appStore.purchases, 0);
    },
  );
  testWidgets('paid users never see plan choices', (tester) async {
    final c = FakeLicensing(FakeStore())..setAccess(paid());
    await openPaywall(tester, c, FakeAccount(c));
    expect(find.text('Monthly'), findsNothing);
    expect(find.text('Yearly'), findsNothing);
    expect(find.text('Continue to export'), findsOneWidget);
  });
  testWidgets('narrow window scrolls without overflow', (tester) async {
    tester.view.physicalSize = const Size(420, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = FakeLicensing(FakeStore());
    await openPaywall(tester, c, FakeAccount(c));
    await tap(tester, 'Yearly');
    await tap(tester, 'Unlock unlimited exports');
    expect(tester.takeException(), isNull);
  });
  test(
    'shared stale license and expired Apple access receive distinct recovery reasons',
    () {
      final now = DateTime.now();
      final shared = EntitlementClaims(
        sub: 'user',
        plan: 'subscription',
        exportEntitled: true,
        status: 'active',
        updatesUntil: null,
        deviceId: 'mac',
        seatLimit: 2,
        issuedAt: now.subtract(const Duration(days: 30)),
        expiresAt: now.subtract(const Duration(days: 1)),
      );
      expect(
        paywallReasonFor(
          EntitlementAppStore(sharedClaims: shared),
          appReleaseDate: now,
        ),
        PaywallReason.licenseCheckRequired,
      );
      expect(
        paywallReasonFor(
          EntitlementAppStore(
            productId: 'com.slipreel.store.monthly',
            expiresAt: now.subtract(const Duration(days: 1)),
          ),
          appReleaseDate: now,
        ),
        PaywallReason.subscriptionLapsed,
      );
    },
  );
}
