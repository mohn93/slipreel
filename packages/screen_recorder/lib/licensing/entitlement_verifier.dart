import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'entitlement_claims.dart';

/// Verifies EdDSA (Ed25519) entitlement JWTs offline against an embedded public
/// key. Returns the claims on success, or null for any invalid/malformed token.
/// Never throws — a bad token is simply "not entitled".
class EntitlementVerifier {
  EntitlementVerifier(this._publicKeyBytes,
      {this.issuer = 'https://api.slipreel.app'});

  final List<int> _publicKeyBytes; // 32-byte Ed25519 public key
  final String issuer;
  final Ed25519 _algorithm = Ed25519();

  Future<EntitlementClaims?> verify(
    String jwt, {
    DateTime? now,
    bool ignoreExpiry = false,
  }) async {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;

      final header = _decodeSegment(parts[0]);
      if (header['alg'] != 'EdDSA') return null;

      final signingInput = utf8.encode('${parts[0]}.${parts[1]}');
      final signature = Signature(
        _decodeBytes(parts[2]),
        publicKey: SimplePublicKey(_publicKeyBytes, type: KeyPairType.ed25519),
      );
      final ok = await _algorithm.verify(signingInput, signature: signature);
      if (!ok) return null;

      final payload = _decodeSegment(parts[1]);
      if (payload['iss'] != issuer) return null;

      final claims = EntitlementClaims.fromJson(payload);
      final at = (now ?? DateTime.now()).toUtc();
      if (!ignoreExpiry && at.isAfter(claims.expiresAt)) return null;
      return claims;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _decodeSegment(String segment) =>
      jsonDecode(utf8.decode(_decodeBytes(segment))) as Map<String, dynamic>;

  List<int> _decodeBytes(String segment) {
    final normalized = segment.replaceAll('-', '+').replaceAll('_', '/');
    final padded = normalized.length % 4 == 0
        ? normalized
        : normalized + '=' * (4 - normalized.length % 4);
    return base64.decode(padded);
  }
}
