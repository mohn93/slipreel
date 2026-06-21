// packages/slipreel_engine/lib/models/device_frame.dart
import 'dart:convert';
import 'package:flutter/painting.dart' show Color;

/// Normalized screen-cutout rect within a bezel image (0..1 of bezel
/// width/height). The video is drawn into this sub-rect.
class DeviceScreenRect {
  final double l, t, r, b;
  const DeviceScreenRect({required this.l, required this.t, required this.r, required this.b});

  double get width => r - l;
  double get height => b - t;

  factory DeviceScreenRect.fromJson(Map<String, dynamic> j) => DeviceScreenRect(
        l: (j['l'] as num).toDouble(),
        t: (j['t'] as num).toDouble(),
        r: (j['r'] as num).toDouble(),
        b: (j['b'] as num).toDouble(),
      );
}

/// One orientation (portrait or landscape) of a colored device bezel.
class DeviceFrameOrientationAsset {
  final String asset;
  final int bezelWidth, bezelHeight;
  final DeviceScreenRect screenRect;
  const DeviceFrameOrientationAsset({
    required this.asset,
    required this.bezelWidth,
    required this.bezelHeight,
    required this.screenRect,
  });

  factory DeviceFrameOrientationAsset.fromJson(Map<String, dynamic> j) {
    final bezel = j['bezel'] as Map<String, dynamic>;
    return DeviceFrameOrientationAsset(
      asset: j['asset'] as String,
      bezelWidth: (bezel['w'] as num).toInt(),
      bezelHeight: (bezel['h'] as num).toInt(),
      screenRect: DeviceScreenRect.fromJson(j['screenRect'] as Map<String, dynamic>),
    );
  }
}

/// A color variant of a device (e.g. "Black Titanium").
class DeviceFrameColorVariant {
  final String id, name;
  final Color swatch;
  final DeviceFrameOrientationAsset portrait, landscape;
  const DeviceFrameColorVariant({
    required this.id,
    required this.name,
    required this.swatch,
    required this.portrait,
    required this.landscape,
  });

  factory DeviceFrameColorVariant.fromJson(Map<String, dynamic> j) => DeviceFrameColorVariant(
        id: j['id'] as String,
        name: j['name'] as String,
        swatch: _parseHexColor(j['swatch'] as String),
        portrait: DeviceFrameOrientationAsset.fromJson(j['portrait'] as Map<String, dynamic>),
        landscape: DeviceFrameOrientationAsset.fromJson(j['landscape'] as Map<String, dynamic>),
      );
}

/// A device model with its native (portrait) screen resolution and
/// available color variants.
class DeviceFrameEntry {
  final String id, family, kind; // kind: 'phone' | 'tablet'
  final int screenWidth, screenHeight; // native portrait px
  final List<DeviceFrameColorVariant> colors;
  const DeviceFrameEntry({
    required this.id,
    required this.family,
    required this.kind,
    required this.screenWidth,
    required this.screenHeight,
    required this.colors,
  });

  DeviceFrameColorVariant? colorById(String id) {
    for (final c in colors) {
      if (c.id == id) return c;
    }
    return null;
  }

  factory DeviceFrameEntry.fromJson(Map<String, dynamic> j) {
    final screen = j['screen'] as Map<String, dynamic>;
    return DeviceFrameEntry(
      id: j['id'] as String,
      family: j['family'] as String,
      kind: j['kind'] as String,
      screenWidth: (screen['w'] as num).toInt(),
      screenHeight: (screen['h'] as num).toInt(),
      colors: (j['colors'] as List)
          .map((e) => DeviceFrameColorVariant.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}

/// In-memory device-frame catalog parsed from `manifest.json`.
class DeviceFrameCatalog {
  final List<DeviceFrameEntry> entries;
  const DeviceFrameCatalog(this.entries);

  factory DeviceFrameCatalog.parse(String jsonStr) {
    final root = jsonDecode(jsonStr) as Map<String, dynamic>;
    final entries = (root['entries'] as List)
        .map((e) => DeviceFrameEntry.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    return DeviceFrameCatalog(entries);
  }

  DeviceFrameEntry? entryById(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }
}

Color _parseHexColor(String hex) {
  var h = hex.replaceFirst('#', '').trim();
  if (h.length == 6) h = 'FF$h';
  return Color(int.parse(h, radix: 16));
}
