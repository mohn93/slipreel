import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The tokens the app caches after activation: the signed entitlement token,
/// the device refresh token, and the server device id (dev_...).
class LicenseTokens {
  const LicenseTokens({
    required this.token,
    required this.refreshToken,
    required this.deviceId,
  });

  final String token;
  final String refreshToken;
  final String deviceId;

  Map<String, dynamic> toJson() =>
      {'token': token, 'refresh': refreshToken, 'device_id': deviceId};

  factory LicenseTokens.fromJson(Map<String, dynamic> json) => LicenseTokens(
        token: json['token'] as String,
        refreshToken: json['refresh'] as String,
        deviceId: json['device_id'] as String,
      );
}

abstract interface class LicenseStore {
  Future<void> save(LicenseTokens tokens);
  Future<LicenseTokens?> load();
  Future<void> clear();
}

/// Test/fallback store; no persistence.
class InMemoryLicenseStore implements LicenseStore {
  LicenseTokens? _tokens;
  @override
  Future<void> save(LicenseTokens tokens) async => _tokens = tokens;
  @override
  Future<LicenseTokens?> load() async => _tokens;
  @override
  Future<void> clear() async => _tokens = null;
}

/// A minimal secure key/value surface so [SecureLicenseStore] is testable
/// without the platform Keychain plugin.
abstract interface class SecureKV {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKV implements SecureKV {
  FlutterSecureKV([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class InMemorySecureKV implements SecureKV {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async => _map[key] = value;
  @override
  Future<void> delete(String key) async => _map.remove(key);
}

/// Keychain-backed license store (via [SecureKV]). Corrupt data loads as null.
class SecureLicenseStore implements LicenseStore {
  SecureLicenseStore(this._kv);
  final SecureKV _kv;
  static const _key = 'slipreel.license';

  @override
  Future<void> save(LicenseTokens tokens) =>
      _kv.write(_key, jsonEncode(tokens.toJson()));

  @override
  Future<LicenseTokens?> load() async {
    final raw = await _kv.read(_key);
    if (raw == null) return null;
    try {
      return LicenseTokens.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> clear() => _kv.delete(_key);
}
