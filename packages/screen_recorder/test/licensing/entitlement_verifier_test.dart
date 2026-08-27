import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement_verifier.dart';

String _b64url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Build a signed EdDSA JWT for tests.
Future<String> _makeJwt(
  SimpleKeyPair kp, {
  required Map<String, dynamic> payload,
  String alg = 'EdDSA',
}) async {
  final header = _b64url(utf8.encode(jsonEncode({'alg': alg, 'typ': 'JWT'})));
  final body = _b64url(utf8.encode(jsonEncode(payload)));
  final signingInput = utf8.encode('$header.$body');
  final sig = await Ed25519().sign(signingInput, keyPair: kp);
  return '$header.$body.${_b64url(sig.bytes)}';
}

Map<String, dynamic> _claims({
  String iss = 'https://api.slipreel.app',
  int? exp,
}) =>
    {
      'sub': 'usr_1', 'iss': iss,
      'iat': 1750000000, 'exp': exp ?? 1900000000,
      'plan': 'subscription', 'export': true, 'status': 'active',
      'updates_until': null, 'device_id': 'dev_1', 'seat_limit': 2,
    };

void main() {
  late SimpleKeyPair kp;
  late List<int> pub;

  setUp(() async {
    kp = await Ed25519().newKeyPair();
    pub = (await kp.extractPublicKey()).bytes;
  });

  test('verifies a valid token and returns claims', () async {
    final jwt = await _makeJwt(kp, payload: _claims());
    final v = EntitlementVerifier(pub);
    final claims = await v.verify(jwt, now: DateTime.utc(2025, 6, 1));
    expect(claims, isNotNull);
    expect(claims!.sub, 'usr_1');
    expect(claims.plan, 'subscription');
  });

  test('rejects a tampered payload', () async {
    final jwt = await _makeJwt(kp, payload: _claims());
    final parts = jwt.split('.');
    final forged = _b64url(utf8.encode(jsonEncode(_claims()..['sub'] = 'attacker')));
    final tampered = '${parts[0]}.$forged.${parts[2]}';
    expect(await EntitlementVerifier(pub).verify(tampered, now: DateTime.utc(2025, 6, 1)), isNull);
  });

  test('rejects a token signed by a different key', () async {
    final other = await Ed25519().newKeyPair();
    final jwt = await _makeJwt(other, payload: _claims());
    expect(await EntitlementVerifier(pub).verify(jwt, now: DateTime.utc(2025, 6, 1)), isNull);
  });

  test('rejects an expired token', () async {
    final jwt = await _makeJwt(kp, payload: _claims(exp: 1750100000));
    expect(await EntitlementVerifier(pub).verify(jwt, now: DateTime.utc(2025, 6, 20)), isNull);
  });

  test('rejects a wrong issuer', () async {
    final jwt = await _makeJwt(kp, payload: _claims(iss: 'https://evil.example'));
    expect(await EntitlementVerifier(pub).verify(jwt, now: DateTime.utc(2025, 6, 1)), isNull);
  });

  test('rejects a non-EdDSA alg header', () async {
    final jwt = await _makeJwt(kp, payload: _claims(), alg: 'HS256');
    expect(await EntitlementVerifier(pub).verify(jwt, now: DateTime.utc(2025, 6, 1)), isNull);
  });

  test('rejects malformed input without throwing', () async {
    final v = EntitlementVerifier(pub);
    expect(await v.verify('not-a-jwt'), isNull);
    expect(await v.verify('a.b'), isNull);
    expect(await v.verify(''), isNull);
  });

  test('ignoreExpiry allows an expired but otherwise valid token', () async {
    final jwt = await _makeJwt(kp, payload: _claims(exp: 1750100000));
    final claims = await EntitlementVerifier(pub)
        .verify(jwt, now: DateTime.utc(2025, 6, 20), ignoreExpiry: true);
    expect(claims, isNotNull);
  });
}
