import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:screen_recorder/store/app_store_client.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/licensing/license_store.dart';
import 'package:screen_recorder/licensing/auth_state_store.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/licensing/entitlement_verifier.dart';
import 'package:screen_recorder/licensing/licensing_api.dart';
import 'package:screen_recorder/licensing/export_gate.dart';

class _CachedFreeVerifier extends EntitlementVerifier {
  _CachedFreeVerifier() : super(List.filled(32, 0));
  @override
  Future<EntitlementClaims?> verify(
    String jwt, {
    DateTime? now,
    bool ignoreExpiry = false,
  }) async => EntitlementClaims(
    sub: 'user',
    plan: 'free',
    exportEntitled: false,
    status: 'none',
    updatesUntil: null,
    deviceId: 'mac',
    seatLimit: 2,
    issuedAt: DateTime.now(),
    expiresAt: DateTime.now().add(const Duration(days: 1)),
  );
}

class _OfflineApi extends LicensingApi {
  @override
  Future<RefreshResult> refresh({
    required String refreshToken,
    required String deviceId,
  }) async => const RefreshTransient();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('slipreel/store');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'fails closed if native and Dart distribution channels disagree',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async => 'direct');
      await expectLater(AppStoreClient().initialize(), throwsStateError);
    },
  );
  test(
    'purchase includes account ownership and preserves pending state',
    () async {
      MethodCall? purchase;
      messenger.setMockMethodCallHandler(channel, (call) async {
        purchase = call;
        return 'pending';
      });
      expect(
        await AppStoreClient().purchase(
          'com.slipreel.store.monthly',
          '11111111-1111-4111-8111-111111111111',
        ),
        'pending',
      );
      expect(purchase!.arguments, {
        'id': 'com.slipreel.store.monthly',
        'appAccountToken': '11111111-1111-4111-8111-111111111111',
      });
    },
  );
  test(
    'signed expiry ends local access and a refunded empty result clears it',
    () async {
      final now = DateTime.now();
      Map<String, Object?> transaction = {
        'productId': 'com.slipreel.store.monthly',
        'expiresAt': now.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      };
      messenger.setMockMethodCallHandler(channel, (call) async => transaction);
      final client = AppStoreClient();
      final access = await client.entitlement();
      expect(canExportNow(access, appReleaseDate: now, now: now), isTrue);
      expect(
        canExportNow(
          access,
          appReleaseDate: now,
          now: now.add(const Duration(minutes: 2)),
        ),
        isFalse,
      );
      transaction = {};
      expect(
        canExportNow(await client.entitlement(), appReleaseDate: now),
        isFalse,
      );
    },
  );
  test('missing expiry and unknown product cannot unlock a monthly plan', () {
    final now = DateTime.now();
    expect(
      const EntitlementAppStore(
        productId: 'com.slipreel.store.monthly',
      ).activeAt(now),
      isFalse,
    );
    expect(
      EntitlementAppStore(
        productId: 'unknown',
        expiresAt: now.add(const Duration(days: 1)),
      ).activeAt(now),
      isFalse,
    );
  });
  test('yearly access expires and billing shows the full annual charge', () {
    final now = DateTime.utc(2026, 9, 12);
    final access = EntitlementAppStore(
      productId: 'com.slipreel.store.yearly',
      expiresAt: now.add(const Duration(days: 365)),
    );
    expect(access.activeAt(now), isTrue);
    expect(access.activeAt(now.add(const Duration(days: 365))), isFalse);
    expect(
      const EntitlementAppStore(
        productId: 'com.slipreel.store.yearly',
      ).activeAt(now),
      isFalse,
    );
    const product = StoreProduct(
      'com.slipreel.store.yearly',
      'Pro Yearly',
      '€79,00',
      'year',
    );
    expect(product.purchaseLabel, 'Yearly · €79,00 / year');
    expect(product.billingLabel, '€79,00 charged yearly. Renews every year.');
  });
  test('shared website entitlement works without an Apple subscription', () {
    final now = DateTime.now();
    final claims = EntitlementClaims(
      sub: 'account',
      plan: 'subscription',
      exportEntitled: true,
      status: 'active',
      updatesUntil: null,
      deviceId: 'mac',
      seatLimit: 2,
      issuedAt: now,
      expiresAt: now.add(const Duration(days: 1)),
    );
    expect(
      canExportNow(
        EntitlementAppStore(sharedClaims: claims),
        appReleaseDate: now,
      ),
      isTrue,
    );
    expect(
      canExportNow(
        EntitlementAppStore(sharedClaims: claims),
        appReleaseDate: now,
        now: now.add(const Duration(days: 2)),
      ),
      isFalse,
    );
  });
  test(
    'store actions never open Stripe or consume a direct checkout callback',
    () async {
      final urls = <Uri>[];
      int plans = 0, accounts = 0;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'channel' ? 'app-store' : <String, Object?>{},
      );
      final storage = InMemoryLicenseStore();
      final controller = LicensingController(
        store: storage,
        verifier: EntitlementVerifier(List.filled(32, 0)),
        api: LicensingApi(),
        authState: AuthStateStore(InMemorySecureKV()),
        appStore: AppStoreClient(),
        openUrl: (url) async {
          urls.add(url);
          return true;
        },
        showStorePlans: () async {
          plans++;
          return true;
        },
        showStoreAccount: () async {
          accounts++;
          return true;
        },
      );
      await controller.load();
      await controller.unlockExport();
      await controller.openSignIn();
      await controller.openAccount();
      await controller.handleDeepLink(
        Uri.parse('slipreel://auth?token=forged&state=forged'),
      );
      expect(urls, isEmpty);
      expect(plans, 1);
      expect(accounts, 2);
      expect(await storage.load(), isNull);
      controller.dispose();
    },
  );
  testWidgets('restore stops waiting when Apple does not return', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) => Completer<void>().future,
    );
    final check = expectLater(
      AppStoreClient().restore(),
      throwsA(isA<TimeoutException>()),
    );
    await tester.pump(const Duration(seconds: 46));
    await check;
  });
  test('yearly savings use numeric prices in the same currency only', () {
    const monthly = StoreProduct(
      'com.slipreel.store.monthly',
      'Pro',
      '\$9',
      'month',
      priceValue: 9,
      currencyCode: 'USD',
    );
    const yearly = StoreProduct(
      'com.slipreel.store.yearly',
      'Pro',
      '\$79',
      'year',
      priceValue: 79,
      currencyCode: 'USD',
    );
    expect(yearly.savingsComparedWith(monthly), 26);
    expect(
      const StoreProduct(
        'com.slipreel.store.yearly',
        'Pro',
        '79 €',
        'year',
        priceValue: 79,
        currencyCode: 'EUR',
      ).savingsComparedWith(monthly),
      isNull,
    );
    expect(
      const StoreProduct(
        'com.slipreel.store.yearly',
        'Pro',
        '\$79',
        'year',
      ).savingsComparedWith(monthly),
      isNull,
    );
  });
  test(
    'shared refresh does not flash free access or discard verified Apple access on native error',
    () async {
      var offline = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'channel') return 'app-store';
        if (offline) throw PlatformException(code: 'offline');
        return {
          'productId': 'com.slipreel.store.monthly',
          'expiresAt': DateTime.now()
              .add(const Duration(days: 1))
              .millisecondsSinceEpoch,
        };
      });
      final storage = InMemoryLicenseStore();
      await storage.save(
        const LicenseTokens(
          token: 'cached-free',
          refreshToken: 'refresh',
          deviceId: 'mac',
        ),
      );
      final controller = LicensingController(
        store: storage,
        verifier: _CachedFreeVerifier(),
        api: _OfflineApi(),
        authState: AuthStateStore(InMemorySecureKV()),
        appStore: AppStoreClient(),
      );
      await controller.load();
      final states = <EntitlementState>[];
      final remove = controller.addListener(states.add, fireImmediately: false);
      offline = true;
      await controller.refreshNow();
      expect(states, isNotEmpty);
      expect(
        states.every(
          (state) =>
              state is EntitlementAppStore &&
              canExportNow(state, appReleaseDate: DateTime.now()),
        ),
        isTrue,
      );
      remove();
      controller.dispose();
    },
  );
}
