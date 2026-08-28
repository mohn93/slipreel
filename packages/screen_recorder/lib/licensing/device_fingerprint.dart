import 'dart:convert';
import 'dart:io';

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

  /// A human label for this Mac, e.g. "Mohanned's MacBook Pro · macOS 15.1".
  /// Best-effort: the computer name comes from the native side and the OS
  /// version from the platform. Returns null if neither is available (so the
  /// server just records an unnamed device rather than a bad label).
  Future<String?> describe() async {
    String? name;
    try {
      name = await _channel.invokeMethod<String>('deviceName');
    } catch (_) {
      name = null;
    }
    name = (name != null && name.trim().isNotEmpty) ? name.trim() : null;
    final os = _macOsLabel();
    if (name == null) return os;
    return os == null ? name : '$name · $os';
  }

  static String? _macOsLabel() {
    try {
      // Platform.operatingSystemVersion looks like "Version 15.1 (Build 24B83)".
      final match = RegExp(r'(\d+\.\d+(?:\.\d+)?)')
          .firstMatch(Platform.operatingSystemVersion);
      return match != null ? 'macOS ${match.group(1)}' : 'macOS';
    } catch (_) {
      return null;
    }
  }
}
