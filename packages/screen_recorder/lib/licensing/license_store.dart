import 'dart:convert';
import 'dart:io';

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

/// File-backed [SecureKV] persisting a JSON map at [path] (typically inside the
/// app-support directory). Used on macOS instead of the Keychain: the platform
/// Keychain (flutter_secure_storage) requires a `keychain-access-groups`
/// entitlement, which forces provisioning-profile signing that a locally-signed
/// / Developer ID build can't carry without extra Apple-portal setup. Storing
/// the token in the user's app-support dir is consistent with the offline
/// licensing threat model (spec §12: the client is inherently patchable).
/// Reads/writes are serialized through an in-memory cache; corrupt/missing
/// files load as empty.
class FileSecureKV implements SecureKV {
  FileSecureKV(this._path);
  final String _path;
  Map<String, String>? _cache;

  Future<Map<String, String>> _loaded() async {
    if (_cache != null) return _cache!;
    try {
      final file = File(_path);
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        _cache = <String, String>{
          for (final e in (decoded as Map<String, dynamic>).entries)
            e.key: e.value as String,
        };
      } else {
        _cache = <String, String>{};
      }
    } catch (_) {
      _cache = <String, String>{};
    }
    return _cache!;
  }

  Future<void> _flush() async {
    final file = File(_path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(_cache));
  }

  @override
  Future<String?> read(String key) async => (await _loaded())[key];

  @override
  Future<void> write(String key, String value) async {
    (await _loaded())[key] = value;
    await _flush();
  }

  @override
  Future<void> delete(String key) async {
    (await _loaded()).remove(key);
    await _flush();
  }
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
