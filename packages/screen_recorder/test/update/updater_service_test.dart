import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/entitlement_claims.dart';
import 'package:screen_recorder/update/updater_backend.dart';
import 'package:screen_recorder/update/updater_service.dart';
import 'package:screen_recorder/update/required_update.dart';

class _FakeBackend implements UpdaterBackend {
  final List<String> calls = [];
  String? feedUrl;
  int? interval;
  Completer<void>? initialization;
  bool failInitialization = false;

  @override
  Future<void> setFeedURL(String url) async {
    feedUrl = url;
    calls.add('setFeedURL');
    if (failInitialization) throw StateError('native initialization failed');
    await initialization?.future;
  }

  @override
  Future<void> setScheduledCheckInterval(int seconds) async {
    interval = seconds;
    calls.add('setScheduledCheckInterval');
  }

  @override
  Future<void> checkForUpdates({bool inBackground = false}) async =>
      calls.add(inBackground ? 'backgroundCheck' : 'checkForUpdates');
}

final _now = DateTime.utc(2026, 9, 11);

EntitlementLoaded _license(
  String plan, {
  DateTime? until,
  String status = 'active',
}) => EntitlementLoaded(
  EntitlementClaims(
    sub: 'user',
    plan: plan,
    exportEntitled: plan != 'free',
    status: status,
    updatesUntil: until,
    deviceId: 'device',
    seatLimit: 2,
    issuedAt: _now.subtract(const Duration(days: 1)),
    expiresAt: _now.add(const Duration(days: 1)),
  ),
);

void main() {
  test('manual update retries a failed startup initialization', () async {
    final backend = _FakeBackend()..failInitialization = true;
    final service = UpdaterService(backend);
    await expectLater(service.init(), throwsStateError);
    backend.failInitialization = false;
    await service.checkForUpdates();
    expect(backend.calls, ['setFeedURL', 'setFeedURL', 'checkForUpdates']);
  });

  test('required updates suppress the optional native prompt', () async {
    final backend = _FakeBackend();
    final update = RequiredUpdate(
      build: 1000020,
      version: '1.0.20',
      releaseDate: _now,
    );
    var policyLoads = 0;
    final service = UpdaterService(
      backend,
      loadRequiredUpdate: () async {
        policyLoads++;
        return update;
      },
    );
    final results = await Future.wait([
      service.checkAtStartup(() => const EntitlementSignedOut()),
      service.checkAtStartup(() => const EntitlementSignedOut()),
    ]);
    expect(results, [update, update]);
    expect(policyLoads, 1);
    expect(backend.calls, ['setFeedURL']);
    await service.checkForUpdates();
    expect(backend.calls, ['setFeedURL', 'checkForUpdates']);
  });

  test('absent or offline policy leaves ordinary updates optional', () async {
    final backend = _FakeBackend();
    final service = UpdaterService(
      backend,
      loadRequiredUpdate: () async => null,
    );
    expect(
      await service.checkAtStartup(() => const EntitlementSignedOut()),
      isNull,
    );
    expect(backend.calls, ['setFeedURL', 'backgroundCheck']);
  });

  test('expired update years never fetch or enforce force policy', () async {
    final backend = _FakeBackend();
    var fetched = false;
    final service = UpdaterService(
      backend,
      loadRequiredUpdate: () async {
        fetched = true;
        return null;
      },
    );
    expect(
      await service.checkAtStartup(
        () =>
            _license('onetime', until: _now.subtract(const Duration(days: 1))),
        now: () => _now,
      ),
      isNull,
    );
    expect(fetched, isFalse);
    expect(backend.calls, isEmpty);
  });

  test('automatic offers follow plan and update-year coverage', () {
    bool allowed(EntitlementState state) =>
        canOfferAutomaticUpdate(state, now: _now);
    expect(allowed(const EntitlementLoading()), isFalse);
    expect(allowed(const EntitlementSignedOut()), isTrue);
    expect(allowed(_license('free')), isTrue);
    expect(
      allowed(_license('onetime', until: _now.add(const Duration(days: 1)))),
      isTrue,
    );
    expect(allowed(_license('onetime', until: _now)), isTrue);
    expect(
      allowed(
        _license(
          'onetime',
          until: _now.subtract(const Duration(microseconds: 1)),
        ),
      ),
      isFalse,
    );
    expect(allowed(_license('onetime')), isFalse);
    expect(allowed(_license('subscription')), isTrue);
    expect(allowed(_license('subscription', status: 'grace')), isTrue);
    expect(allowed(_license('subscription', status: 'canceled')), isFalse);
    expect(
      canOfferAutomaticUpdate(
        _license('subscription'),
        now: _now.add(const Duration(days: 1)),
      ),
      isFalse,
    );
  });

  test('waits for licensing and checks once after coverage renewal', () async {
    final backend = _FakeBackend();
    final service = UpdaterService(backend);
    EntitlementState state = const EntitlementLoading();
    Future<dynamic> check() =>
        service.checkAtStartup(() => state, now: () => _now);
    await check();
    state = _license('onetime', until: _now.subtract(const Duration(days: 1)));
    await check();
    expect(backend.calls, isEmpty);
    state = _license('onetime', until: _now.add(const Duration(days: 365)));
    await Future.wait([check(), check()]);
    await check();
    expect(backend.calls, ['setFeedURL', 'backgroundCheck']);
  });

  test(
    'free startup uses background check without a manual up-to-date dialog',
    () async {
      final backend = _FakeBackend();
      await UpdaterService(backend).checkAtStartup(() => _license('free'));
      expect(backend.calls, ['setFeedURL', 'backgroundCheck']);
    },
  );

  test(
    'rechecks eligibility if licensing changes during initialization',
    () async {
      final backend = _FakeBackend()..initialization = Completer<void>();
      final service = UpdaterService(backend);
      EntitlementState state = const EntitlementSignedOut();
      final check = service.checkAtStartup(() => state, now: () => _now);
      state = _license(
        'onetime',
        until: _now.subtract(const Duration(days: 1)),
      );
      backend.initialization!.complete();
      await check;
      expect(backend.calls, ['setFeedURL']);
    },
  );

  test(
    'init sets the feed once without enabling automatic update checks',
    () async {
      final backend = _FakeBackend();
      final service = UpdaterService(backend);

      await service.init();
      await service.init(); // second call must not re-configure

      expect(backend.feedUrl, 'https://slipreel.app/appcast.xml');
      expect(backend.interval, isNull);
      expect(backend.calls.where((c) => c == 'setFeedURL').length, 1);
    },
  );

  test('checkForUpdates delegates to the backend', () async {
    final backend = _FakeBackend();
    final service = UpdaterService(backend);

    await service.checkForUpdates();

    expect(backend.calls, contains('checkForUpdates'));
  });
}
