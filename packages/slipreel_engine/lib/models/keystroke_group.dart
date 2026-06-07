import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Default max gap between two presses of the SAME label for them to be
/// treated as one repeated shortcut (coalesced into a single keycap with a
/// ×N count) rather than two separate presses.
const int kKeystrokeRepeatGapMicros = 1500000; // 1.5s

/// A run of one-or-more consecutive presses of the same label, close enough
/// in time to read as a single (possibly repeated) shortcut.
class KeystrokeGroup {
  const KeystrokeGroup({
    required this.label,
    required this.firstMicros,
    required this.lastMicros,
    required this.count,
  });

  final String label;

  /// Timestamp of the first press in the run.
  final int firstMicros;

  /// Timestamp of the most recent press — drives the overlay fade + pulse.
  final int lastMicros;

  /// Number of presses coalesced into this group.
  final int count;
}

/// Coalesces consecutive same-label events whose presses are within
/// [maxGapMicros] of each other into [KeystrokeGroup]s. Input must already
/// be in ascending timestamp order (as [KeystrokeRecording] keeps it) and
/// pre-filtered to only the events that should display.
List<KeystrokeGroup> coalesceKeystrokes(
  List<KeystrokeEvent> events, {
  int maxGapMicros = kKeystrokeRepeatGapMicros,
}) {
  final groups = <KeystrokeGroup>[];
  for (final e in events) {
    if (groups.isNotEmpty) {
      final last = groups.last;
      if (last.label == e.label &&
          e.timestampMicros - last.lastMicros <= maxGapMicros) {
        groups[groups.length - 1] = KeystrokeGroup(
          label: last.label,
          firstMicros: last.firstMicros,
          lastMicros: e.timestampMicros,
          count: last.count + 1,
        );
        continue;
      }
    }
    groups.add(KeystrokeGroup(
      label: e.label,
      firstMicros: e.timestampMicros,
      lastMicros: e.timestampMicros,
      count: 1,
    ));
  }
  return groups;
}
