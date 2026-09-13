import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../licensing/license_store.dart';
import '../licensing/licensing_config.dart';

class NotificationController extends ChangeNotifier {
  NotificationController({
    required this.storage,
    required this.licenses,
    required this.channelName,
    http.Client? client,
  }) : client = client ?? http.Client();
  final SecureKV storage;
  final LicenseStore licenses;
  final String channelName;
  final http.Client client;
  final native = const MethodChannel('slipreel/notifications');
  String permission = 'notDetermined';
  String? error, policyMessage;
  bool blocked = false, maintenance = false, configured = false, busy = false;
  List<Map<String, dynamic>> messages = [];
  int _generation = 0;
  String? _lastDeviceId;
  Timer? _timer;
  Future<void>? _syncing;
  VoidCallback? openInbox;
  Future<void> start() async {
    if (!Platform.isMacOS) return;
    native.setMethodCallHandler((call) async {
      if (call.method == 'openInbox') openInbox?.call();
      if (call.method == 'changed' || call.method == 'openInbox') await sync();
    });
    _timer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(sync()),
    );
    await sync();
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await client
        .post(
          Uri.parse('${LicensingConfig.apiBaseResolved}/v1/installations$path'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode >= 400) {
      throw const HttpException('Notification service unavailable');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> sync() =>
      _syncing ??= _sync().whenComplete(() => _syncing = null);
  Future<void> _sync() async {
    final generation = _generation;
    try {
      final status =
          await native.invokeMapMethod<String, dynamic>('status') ?? {};
      permission = status['permission'] as String? ?? 'notDetermined';
      configured = status['configured'] == true;
      final registration = {
        'name': Platform.localHostname,
        'channel': channelName,
        'permission': permission,
        'apnsToken': status['apnsToken'],
        'environment': status['environment'] ?? 'production',
        'version': const String.fromEnvironment(
          'FLUTTER_BUILD_NUMBER',
          defaultValue: 'unknown',
        ),
      };
      var raw = await storage.read('notification-installation');
      if (raw == null) {
        final identity = await _post('', registration);
        raw = jsonEncode(identity);
        await storage.write('notification-installation', raw);
      }
      final identity = jsonDecode(raw) as Map<String, dynamic>;
      final tokens = await licenses.load();
      _lastDeviceId = tokens?.deviceId;
      final result = await _post('/sync', {
        ...identity,
        'registration': registration,
        'device': tokens == null
            ? null
            : {'id': tokens.deviceId, 'refreshToken': tokens.refreshToken},
      });
      final inbox = await _post('/inbox', identity);
      if (generation != _generation) return;
      final policy = result['policy'] as Map;
      blocked = policy['blocked'] == true;
      maintenance = policy['maintenance'] == true;
      policyMessage = policy['message'] as String?;
      messages = (inbox['messages'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      error = null;
    } catch (_) {
      error = 'Messages are temporarily unavailable. Try again shortly.';
    }
    notifyListeners();
  }

  Future<void> accountChanged() async {
    _generation++;
    final deviceId = (await licenses.load())?.deviceId;
    if (deviceId != _lastDeviceId) {
      messages = [];
      blocked = false;
      policyMessage = null;
      notifyListeners();
    }
    await _syncing;
    await sync();
  }

  Future<void> enable() async {
    busy = true;
    notifyListeners();
    try {
      await native.invokeMethod<void>(
        permission == 'denied' ? 'openSettings' : 'requestPermission',
      );
      await sync();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Call before new exports; never terminates a running pipeline.
  Future<bool> allowPaidExport() async {
    await sync();
    return !blocked && !maintenance;
  }

  @override
  void dispose() {
    _timer?.cancel();
    native.setMethodCallHandler(null);
    client.close();
    super.dispose();
  }
}

final notificationControllerProvider =
    ChangeNotifierProvider<NotificationController?>((ref) => null);
