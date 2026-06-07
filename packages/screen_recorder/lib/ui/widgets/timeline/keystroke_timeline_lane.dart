import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/keystroke_group.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/models/keystroke_recording.dart';
import 'package:slipreel_engine/rendering/keystroke_overlay.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'timeline_constants.dart';

/// Horizontal lane that lays out keycap badges for captured shortcuts at
/// their edited-time position on the timeline. Reuses the on-canvas keycap
/// styling ([KeystrokeKeycap]) so the lane and the video overlay read as
/// one feature.
///
/// Only events that pass the display filter are shown (real shortcuts
/// always; single nav/action keys when opted in; plain typing never), and
/// events that fall inside trimmed-away source regions are dropped.
class KeystrokeTimelineLane extends StatelessWidget {
  const KeystrokeTimelineLane({
    super.key,
    required this.recording,
    required this.settings,
    required this.clips,
    required this.pixelsPerSecond,
    required this.contentWidth,
    this.onToggle,
  });

  final KeystrokeRecording recording;
  final KeystrokeOverlaySettings settings;
  final List<ClipSlice> clips;
  final double pixelsPerSecond;
  final double contentWidth;

  /// Fired when a bar is tapped to enable/disable that shortcut occurrence.
  final ValueChanged<KeystrokeGroup>? onToggle;

  // Timeline keycaps are a fixed, compact size regardless of the on-video
  // "labels size" slider — that slider only governs the overlay so the lane
  // stays tidy at any setting. Tuned to fit [keystrokeLaneHeight].
  static const double _keycapScale = 0.5;

  // Enabled bars get a clear blue rim; disabled bars are dimmed with a faint
  // grey rim so they read as "off" while staying re-enable-able.
  static const Color _enabledFill = Color(0xFF22223A);
  static const Color _enabledBorder = Color(0xFF4F8FF5);
  static const Color _disabledFill = Color(0xFF191922);
  static const Color _disabledBorder = Color(0x33FFFFFF);

  @override
  Widget build(BuildContext context) {
    // Filter to displayable + visible (in source order), then coalesce
    // rapid repeats of the same shortcut into one keycap with a ×N count so
    // they don't pile up on top of each other.
    final shown = <KeystrokeEvent>[];
    for (final e in recording.events) {
      if (!settings.shouldDisplay(e.kind)) continue;
      if (!_isVisible(Duration(microseconds: e.timestampMicros))) continue;
      shown.add(e);
    }
    final groups = coalesceKeystrokes(shown);

    final caps = <Widget>[];
    for (final g in groups) {
      final sourceTime = Duration(microseconds: g.firstMicros);
      final editedTime =
          clips.isEmpty ? sourceTime : sourceToEdited(clips, sourceTime);
      final x = timeToX(editedTime, pixelsPerSecond);
      final enabled = settings.isKeyEnabled(g.firstMicros);
      caps.add(
        Positioned(
          left: x,
          top: 0,
          bottom: 0,
          // Centre the keycap horizontally on its event time.
          child: FractionalTranslation(
            translation: const Offset(-0.5, 0),
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap:
                    onToggle == null ? null : () => onToggle!.call(g),
                child: Opacity(
                  opacity: enabled ? 1.0 : 0.55,
                  child: KeystrokeKeycap(
                    label: g.label,
                    count: g.count,
                    scale: _keycapScale,
                    fill: enabled ? _enabledFill : _disabledFill,
                    border: enabled ? _enabledBorder : _disabledBorder,
                    textColor:
                        enabled ? Colors.white : Colors.white60,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: contentWidth,
      height: keystrokeLaneHeight,
      child: Stack(clipBehavior: Clip.none, children: caps),
    );
  }

  /// A source time is visible only if it falls inside some surviving slice's
  /// [trimStart, trimEnd] range. Empty clips ⇒ unedited ⇒ everything visible.
  bool _isVisible(Duration sourceTime) {
    if (clips.isEmpty) return true;
    for (final c in clips) {
      if (sourceTime >= c.trimStart && sourceTime <= c.trimEnd) return true;
    }
    return false;
  }
}
