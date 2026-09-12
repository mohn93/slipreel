import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../licensing/license_store.dart';
import '../licensing/licensing_config.dart';
import '../licensing/licensing_controller.dart';
import '../licensing/device_fingerprint.dart';

class AccountError implements Exception {
  const AccountError(this.message);
  final String message;
  @override
  String toString() => message;
}

class NativeAccount extends ChangeNotifier {
  NativeAccount(this.licensing, {SecureKV? storage, http.Client? httpClient})
    : storage = storage ?? FlutterSecureKV(),
      client = httpClient ?? http.Client();
  final LicensingController licensing;
  final SecureKV storage;
  final http.Client client;
  String? _session, email, appAccountToken;
  int _generation = 0;
  bool get signedIn => email != null && appAccountToken != null;
  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, dynamic>? body,
    String method = 'POST',
  }) async {
    _session ??= await storage.read('native-account-session');
    final request = http.Request(
      method,
      Uri.parse('${LicensingConfig.apiBaseResolved}/v1/native/$path'),
    );
    request.headers['content-type'] = 'application/json';
    if (_session != null) request.headers['authorization'] = 'Bearer $_session';
    if (body != null) request.body = jsonEncode(body);
    final generation = _generation;
    final response = await http.Response.fromStream(
      await client.send(request).timeout(const Duration(seconds: 20)),
    ).timeout(const Duration(seconds: 20));
    if (generation != _generation) {
      throw const AccountError('Account changed. Please try again.');
    }
    if (response.statusCode >= 400) {
      final code = (jsonDecode(response.body) as Map)['error'];
      if (code == 'not_authenticated') {
        await _clear();
      }
      throw AccountError(switch (code) {
        'invalid_code' =>
          'That code is invalid or expired. Request a new code.',
        'seat_limit' =>
          'Your account has reached its device limit. Remove a device from your account before activating this Mac.',
        'purchase_not_linked' =>
          'This purchase could not be linked. Sign in with the Slipreel account used when subscribing, then restore again.',
        'not_authenticated' => 'Please sign in again.',
        _ => 'The account service is unavailable. Please try again.',
      });
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> load() async {
    _session ??= await storage.read('native-account-session');
    if (_session == null) return;
    final generation = _generation;
    final data = await request('account', method: 'GET');
    if (generation != _generation) return;
    final user = data['user'] as Map;
    email = user['email'] as String;
    appAccountToken = user['app_account_token'] as String;
    notifyListeners();
  }

  Future<String> sendCode(String email) async =>
      (await request(
            'email/request',
            body: {'email': email.trim()},
          ))['challenge']
          as String;
  Future<void> verifyCode(String challenge, String code) async => _accept(
    await request(
      'email/verify',
      body: {'challenge': challenge, 'code': code.trim()},
    ),
  );
  Future<void> signInWithApple() async {
    final challenge = await request('apple/challenge', body: {});
    final credential = await licensing.appStore!.channel
        .invokeMapMethod<String, dynamic>('appleSignIn', {
          'nonce': challenge['nonce'],
          'state': challenge['challenge'],
        });
    if (credential == null || credential['state'] != challenge['challenge']) {
      throw const AccountError('Apple sign-in did not finish.');
    }
    await _accept(
      await request(
        'apple/verify',
        body: {
          'challenge': challenge['challenge'],
          'identityToken': credential['identityToken'],
          'code': credential['code'],
        },
      ),
    );
  }

  Future<void> _accept(Map<String, dynamic> data) async {
    _generation++;
    _session = data['session'] as String;
    await storage.write('native-account-session', _session!);
    await load();
    await activate();
  }

  Future<void> activate() async {
    final generation = _generation;
    final fingerprint = DeviceFingerprint();
    final data = await request(
      'activate',
      body: {
        'fingerprint': await fingerprint.compute(),
        'name': await fingerprint.describe() ?? 'Mac',
      },
    );
    if (generation != _generation) return;
    await licensing.activateNative(
      LicenseTokens(
        token: data['token'] as String,
        refreshToken: data['refresh_token'] as String,
        deviceId: data['device_id'] as String,
      ),
    );
  }

  Future<void>? _syncing;
  Future<void> syncPurchases() =>
      _syncing ??= _sync().whenComplete(() => _syncing = null);
  Future<void> _sync() async {
    if (!signedIn) return;
    for (final transaction in await licensing.appStore!.signedTransactions()) {
      await request('apple/purchase', body: {'signedTransaction': transaction});
    }
    await activate();
  }

  Future<void> _clear() async {
    _generation++;
    _session = null;
    email = null;
    appAccountToken = null;
    await storage.delete('native-account-session');
    notifyListeners();
  }

  Future<void> signOut() async {
    try {
      await request('logout', body: {});
    } finally {
      await _clear();
      await licensing.signOut();
    }
  }

  Future<void> deleteAccount() async {
    await request('account', method: 'DELETE', body: {'confirm': 'DELETE'});
    await _clear();
    await licensing.signOut();
  }

  @override
  void dispose() {
    client.close();
    super.dispose();
  }
}

final nativeAccountProvider = ChangeNotifierProvider<NativeAccount>(
  (ref) => NativeAccount(ref.read(licensingControllerProvider.notifier)),
);
