import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_recorder/licensing/license_store.dart';
import 'package:screen_recorder/notifications/notification_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('slipreel/notifications'),
          (call) async => {
            'permission': 'denied',
            'apnsToken': null,
            'environment': 'production',
            'configured': true,
          },
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('slipreel/notifications'),
          null,
        );
  });
  test(
    'registers an anonymous installation, then links verified device credentials',
    () async {
      final licenses = InMemoryLicenseStore();
      final requests = <Map<String, dynamic>>[];
      final state = NotificationController(
        storage: InMemorySecureKV(),
        licenses: licenses,
        channelName: 'app-store',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path.endsWith('/sync')) {
            requests.add(body);
            return http.Response(
              jsonEncode({
                'policy': {
                  'blocked': false,
                  'maintenance': false,
                  'message': null,
                },
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/inbox'))
            return http.Response('{"messages":[]}', 200);
          return http.Response('{"id":"installation","secret":"secret"}', 200);
        }),
      );
      await state.sync();
      expect(requests.single['device'], null);
      expect(state.permission, 'denied');
      await licenses.save(
        const LicenseTokens(
          token: 'license',
          refreshToken: 'credential',
          deviceId: 'device1',
        ),
      );
      await state.accountChanged();
      expect((requests.last['device'] as Map)['id'], 'device1');
      await licenses.clear();
      await state.accountChanged();
      expect(requests.last['device'], null);
      state.dispose();
    },
  );
  test(
    'maintenance denies new paid exports and a successful refresh unblocks',
    () async {
      var maintenance = true;
      final state = NotificationController(
        storage: InMemorySecureKV(),
        licenses: InMemoryLicenseStore(),
        channelName: 'direct',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/sync'))
            return http.Response(
              jsonEncode({
                'policy': {
                  'blocked': false,
                  'maintenance': maintenance,
                  'message': maintenance ? 'Back soon' : null,
                },
              }),
              200,
            );
          if (request.url.path.endsWith('/inbox'))
            return http.Response('{"messages":[]}', 200);
          return http.Response('{"id":"installation","secret":"secret"}', 200);
        }),
      );
      expect(await state.allowPaidExport(), false);
      expect(state.policyMessage, 'Back soon');
      maintenance = false;
      expect(await state.allowPaidExport(), true);
      state.dispose();
    },
  );
  test('a transport failure preserves the last known restriction', () async {
    var offline = false;
    final state = NotificationController(
      storage: InMemorySecureKV(),
      licenses: InMemoryLicenseStore(),
      channelName: 'direct',
      client: MockClient((request) async {
        if (offline) throw Exception('offline');
        if (request.url.path.endsWith('/sync'))
          return http.Response(
            '{"policy":{"blocked":true,"maintenance":false,"message":"Contact support"}}',
            200,
          );
        if (request.url.path.endsWith('/inbox'))
          return http.Response('{"messages":[]}', 200);
        return http.Response('{"id":"installation","secret":"secret"}', 200);
      }),
    );
    expect(await state.allowPaidExport(), false);
    offline = true;
    expect(await state.allowPaidExport(), false);
    expect(state.error, isNotNull);
    state.dispose();
  });
}
