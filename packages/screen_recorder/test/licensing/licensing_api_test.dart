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
}
