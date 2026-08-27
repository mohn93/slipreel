import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Thrown when the platform cannot supply a stable hardware id.
class DeviceFingerprintUnavailable implements Exception {
  const DeviceFingerprintUnavailable();
  @override
  String toString() => 'DeviceFingerprintUnavailable';
}

/// Stable per-machine fingerprint: sha256 of the macOS IOPlatformUUID, fetched
/// over the `slipreel/device` channel (handled in MainFlutterWindow.swift).
/// The raw UUID never leaves the device; only its hash is sent to the server.
class DeviceFingerprint {
  DeviceFingerprint({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('slipreel/device');

  final MethodChannel _channel;

  Future<String> compute() async {
    final raw = await _channel.invokeMethod<String>('hardwareId');
    if (raw == null || raw.isEmpty) {
      throw const DeviceFingerprintUnavailable();
    }
    return sha256.convert(utf8.encode(raw)).toString();
  }
}
