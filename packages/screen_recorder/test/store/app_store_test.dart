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
}
