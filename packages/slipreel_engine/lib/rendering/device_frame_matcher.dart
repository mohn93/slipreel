// packages/slipreel_engine/lib/rendering/device_frame_matcher.dart
import 'package:flutter/painting.dart';

import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/window_frame.dart';

bool recordingIsPortrait(Size recording) => recording.height >= recording.width;

/// Device form factor inferred from a recording's pixel size, by aspect
/// ratio normalised to landscape (orientation-independent).
enum RecordingFormFactor { phone, tablet }

/// Landscape-aspect boundary separating tablet-like (≤) from phone-like (>)
/// recordings. Every Apple iPad is ≤ 1.52 (the mini; most are ≤ 1.45);
/// every iPhone is ≥ 1.78. 1.6 leaves margin on both sides.
const double kPhoneTabletAspectSplit = 1.6;

/// Classifies [recording] as a phone or tablet by its landscape-normalised
/// aspect ratio. Returns null for a degenerate (zero/negative) size so
/// callers can choose not to filter before the size is known.
RecordingFormFactor? recordingFormFactor(Size recording) {
  final w = recording.width;
  final h = recording.height;
  if (w <= 0 || h <= 0) return null;
  final landscapeAspect = w >= h ? w / h : h / w;
  return landscapeAspect <= kPhoneTabletAspectSplit
      ? RecordingFormFactor.tablet
      : RecordingFormFactor.phone;
}

/// Whether [entry]'s kind matches the recording's inferred form factor.
/// A degenerate [recording] size is treated as compatible (do not
/// over-filter before the size is known).
bool deviceFrameCompatible(DeviceFrameEntry entry, Size recording) {
  final ff = recordingFormFactor(recording);
  if (ff == null) return true;
  final wantTablet = ff == RecordingFormFactor.tablet;
  return (entry.kind == 'tablet') == wantTablet;
}

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

/// Returns catalog entries whose form factor is compatible with the
/// recording (see [deviceFrameCompatible]): phones for a phone-shaped
/// recording, tablets for a tablet-shaped one. A degenerate [recording]
/// size yields every entry (no filtering).
///
/// This is the "Flexible" picker behavior: any same-kind device, scaled
/// by the renderer to fit — as opposed to [perfectMatches]' exact match.
List<DeviceFrameEntry> flexibleMatches(DeviceFrameCatalog c, Size recording) =>
    [for (final e in c.entries) if (deviceFrameCompatible(e, recording)) e];

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
