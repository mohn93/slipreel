// packages/slipreel_engine/lib/rendering/device_frame_matcher.dart
import 'package:flutter/painting.dart';

import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/window_frame.dart';

bool recordingIsPortrait(Size recording) => recording.height >= recording.width;

/// Exact, orientation-aware match between a device's native screen
/// resolution and the recording's pixel size.
bool deviceMatchesRecording(DeviceFrameEntry entry, Size recording) {
  final w = recording.width.round();
  final h = recording.height.round();
  if (recordingIsPortrait(recording)) {
    return entry.screenWidth == w && entry.screenHeight == h;
  }
  return entry.screenWidth == h && entry.screenHeight == w;
}

List<DeviceFrameEntry> perfectMatches(DeviceFrameCatalog c, Size recording) =>
    [for (final e in c.entries) if (deviceMatchesRecording(e, recording)) e];

/// All entries whose *kind* fits a portrait/landscape recording — used
/// for the "Flexible" picker (scaled to fit, not exact).
List<DeviceFrameEntry> flexibleMatches(DeviceFrameCatalog c, Size recording) =>
    List<DeviceFrameEntry>.from(c.entries);

DeviceFrameEntry? autoSelectDeviceFrame(DeviceFrameCatalog c, Size recording) {
  final matches = perfectMatches(c, recording);
  return matches.isEmpty ? null : matches.first;
}

/// Returns [current] unchanged unless the device frame is OFF
/// (`deviceFrameId == null`) and a perfect match exists, in which case
/// it enables that device with its first color.
WindowFrame windowFrameWithAutoDeviceFrame({
  required WindowFrame current,
  required DeviceFrameCatalog catalog,
  required Size recording,
}) {
  if (current.deviceFrameId != null) return current;
  final match = autoSelectDeviceFrame(catalog, recording);
  if (match == null || match.colors.isEmpty) return current;
  return current.copyWith(
    deviceFrameId: match.id,
    deviceFrameColor: match.colors.first.id,
  );
}
