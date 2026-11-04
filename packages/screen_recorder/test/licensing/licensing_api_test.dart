import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_recorder/licensing/licensing_api.dart';

void main() {
  test('refresh posts refresh_token + device_id and returns RefreshOk', () async {
    late http.Request seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response(jsonEncode({'token': 'new.jwt.here'}), 200,
          headers: {'content-type': 'application/json'});
    });
    final api = LicensingApi(baseUrl: 'https://api.example.test', client: client);
    final result = await api.refresh(refreshToken: 'rt_123', deviceId: 'dev_9');

    expect(result, isA<RefreshOk>());
    expect((result as RefreshOk).token, 'new.jwt.here');
    expect(seen.url.toString(), 'https://api.example.test/v1/token/refresh');
    expect(seen.method, 'POST');
    final body = jsonDecode(seen.body) as Map<String, dynamic>;
    expect(body['refresh_token'], 'rt_123');
    expect(body['device_id'], 'dev_9');
    expect(seen.headers['content-type'], contains('application/json'));
  });

  test('refresh is RefreshRevoked on 401 (seat deactivated)', () async {
    final client = MockClient((req) async =>
        http.Response(jsonEncode({'error': 'invalid refresh token'}), 401));
    final api = LicensingApi(baseUrl: 'https://api.example.test', client: client);
    expect(await api.refresh(refreshToken: 'x', deviceId: 'y'),
        isA<RefreshRevoked>());
  });

  test('account restriction preserves identity for policy checks', () async {
    final client = MockClient((req) async => http.Response('{"error":"account_restricted"}', 403));
    final api = LicensingApi(client: client);
    expect(await api.refresh(refreshToken: 'r', deviceId: 'd'), isA<RefreshTransient>());
  });

  test('refresh is RefreshRevoked on 403', () async {
    final client = MockClient((req) async => http.Response('forbidden', 403));
    final api = LicensingApi(baseUrl: 'https://api.example.test', client: client);
    expect(await api.refresh(refreshToken: 'x', deviceId: 'y'),
        isA<RefreshRevoked>());
  });

  test('refresh is RefreshTransient on network error', () async {
    final client = MockClient((req) async => throw http.ClientException('down'));
    final api = LicensingApi(baseUrl: 'https://api.example.test', client: client);
    expect(await api.refresh(refreshToken: 'x', deviceId: 'y'),
        isA<RefreshTransient>());
  });

  test('refresh is RefreshTransient on 5xx (server error, not a revocation)',
      () async {
    final client = MockClient((req) async => http.Response('boom', 503));
    final api = LicensingApi(baseUrl: 'https://api.example.test', client: client);
    expect(await api.refresh(refreshToken: 'x', deviceId: 'y'),
        isA<RefreshTransient>());
  });

  test('refresh is RefreshTransient when a 200 body has no token', () async {
    final client =
        MockClient((req) async => http.Response(jsonEncode({'ok': true}), 200));
    final api = LicensingApi(baseUrl: 'https://api.example.test', client: client);
    expect(await api.refresh(refreshToken: 'x', deviceId: 'y'),
        isA<RefreshTransient>());
  });

  group('claimHandoff', () {
    LicensingApi api(int status, String body, [void Function(http.Request)? seen]) =>
        LicensingApi(
          baseUrl: 'https://api.example.test',
          client: MockClient((req) async {
            seen?.call(req);
            return http.Response(body, status);
          }),
        );

    test('posts state + fingerprint and returns credentials on 200', () async {
      http.Request? sent;
      final r = await api(200,
              '{"token":"t","refresh_token":"r","device_id":"dev_1"}',
              (req) => sent = req)
          .claimHandoff(state: 'h1.s', fingerprint: 'fp');
      expect(sent!.url.path, '/v1/auth/handoff/claim');
      expect(jsonDecode(sent!.body), {'state': 'h1.s', 'fingerprint': 'fp'});
      expect(r, isA<HandoffCredentials>());
      expect((r as HandoffCredentials).refreshToken, 'r');
    });

    test('204 is pending', () async {
      expect(await api(204, '').claimHandoff(state: 's', fingerprint: 'f'),
          isA<HandoffPending>());
    });

    test('409 carries the error', () async {
      final r = await api(409, '{"error":"seat_limit"}')
          .claimHandoff(state: 's', fingerprint: 'f');
      expect((r as HandoffFailed).error, 'seat_limit');
    });

    test('5xx and malformed bodies are pending', () async {
      expect(await api(503, 'x').claimHandoff(state: 's', fingerprint: 'f'),
          isA<HandoffPending>());
      expect(await api(200, '{"token":1}').claimHandoff(state: 's', fingerprint: 'f'),
          isA<HandoffPending>());
    });
  });
}
