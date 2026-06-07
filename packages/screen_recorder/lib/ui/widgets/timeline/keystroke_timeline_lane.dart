import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/keystroke_group.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/models/keystroke_recording.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'timeline_constants.dart';

/// Horizontal lane that lays out a bar per captured shortcut on the timeline.
///
/// Each bar starts at the press and would span the window the on-video badge
/// is visible (`press → lastPress + fade`), but bars are PACKED into one row:
/// a bar is clamped to end where the next shortcut begins, so they never
/// overlap. Isolated shortcuts keep their full duration; rapid bursts become
/// a tidy row of adjacent segments. Hovering a bar expands it back to its full
/// window (floating above neighbours) so a clipped key label can be read.
///
/// Rapid repeats of the same shortcut coalesce into one bar with a ×N count.
/// Only events that pass the display filter are shown; events inside
/// trimmed-away source regions are dropped. Tapping a bar toggles that
/// occurrence on/off: enabled = blue rim, disabled = dimmed grey rim.
class KeystrokeTimelineLane extends StatefulWidget {
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

  @override
  State<KeystrokeTimelineLane> createState() => _KeystrokeTimelineLaneState();
}

class _KeystrokeTimelineLaneState extends State<KeystrokeTimelineLane> {
  static const double _barHeight = 26;
  // Gap kept between packed bars and the smallest a clamped bar shrinks to.
  static const double _gap = 2;
  static const double _minWidth = 22;

  // firstMicros of the currently-hovered bar (stable across rebuilds), or null.
  int? _hoveredKey;

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final clips = widget.clips;

    // Filter to displayable + visible (in source order), then coalesce rapid
    // repeats of the same shortcut into one group with a ×N count.
    final shown = <KeystrokeEvent>[];
    for (final e in widget.recording.events) {
      if (!s.shouldDisplay(e.kind)) continue;
      if (!_isVisible(Duration(microseconds: e.timestampMicros))) continue;
      shown.add(e);
    }
    final groups = coalesceKeystrokes(shown);
    final fadeMicros = (s.fadeSecs * 1e6).round();
    final cw = widget.contentWidth;
    final top = (keystrokeLaneHeight - _barHeight) / 2;

    // Pass 1: each bar's left + natural (full-window) right edge.
    final layout = <_BarLayout>[];
    for (final g in groups) {
      final startSrc = Duration(microseconds: g.firstMicros);
      final endSrc = Duration(microseconds: g.lastMicros + fadeMicros);
      final startEdited =
          clips.isEmpty ? startSrc : sourceToEdited(clips, startSrc);
      final endEdited = clips.isEmpty ? endSrc : sourceToEdited(clips, endSrc);
      final xStart = timeToX(startEdited, widget.pixelsPerSecond)
          .clamp(0.0, cw)
          .toDouble();
      final xEndNatural = timeToX(endEdited, widget.pixelsPerSecond)
          .clamp(0.0, cw)
          .toDouble();
      layout.add(_BarLayout(
        group: g,
        xStart: xStart,
        xEndNatural: math.max(xStart + _minWidth, xEndNatural),
        enabled: s.isKeyEnabled(g.firstMicros),
      ));
    }

    // Pass 2: clamp each bar to end where the next one starts (packed row).
    final bars = <Widget>[];
    for (var i = 0; i < layout.length; i++) {
      final b = layout[i];
      final nextStart = i + 1 < layout.length ? layout[i + 1].xStart : cw;
      final clampedEnd =
          math.min(b.xEndNatural, math.max(b.xStart, nextStart - _gap));
      final clampedWidth = math.max(_minWidth, clampedEnd - b.xStart);
      final naturalWidth = math.max(_minWidth, b.xEndNatural - b.xStart);
      final hovered = _hoveredKey == b.group.firstMicros;
      final width = hovered ? naturalWidth : clampedWidth;

      bars.add(AnimatedPositioned(
        key: ValueKey(b.group.firstMicros),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        left: b.xStart,
        top: top,
        width: width,
        height: _barHeight,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hoveredKey = b.group.firstMicros),
          onExit: (_) => setState(() {
            if (_hoveredKey == b.group.firstMicros) _hoveredKey = null;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onToggle == null
                ? null
                : () => widget.onToggle!.call(b.group),
            child: _ShortcutBar(
              label: b.group.label,
              count: b.group.count,
              enabled: b.enabled,
              hovered: hovered,
            ),
          ),
        ),
      ));
    }

    // Draw the hovered bar last so its expanded width floats above neighbours.
    if (_hoveredKey != null) {
      final idx =
          layout.indexWhere((b) => b.group.firstMicros == _hoveredKey);
      if (idx != -1 && idx < bars.length) {
        bars.add(bars.removeAt(idx));
      }
    }

    return SizedBox(
      width: cw,
      height: keystrokeLaneHeight,
      // Clip.none so the hover-expanded bar can overhang to the right.
      child: Stack(clipBehavior: Clip.none, children: bars),
    );
  }

  /// A source time is visible only if it falls inside some surviving slice's
  /// [trimStart, trimEnd] range. Empty clips ⇒ unedited ⇒ everything visible.
  bool _isVisible(Duration sourceTime) {
    final clips = widget.clips;
    if (clips.isEmpty) return true;
    for (final c in clips) {
      if (sourceTime >= c.trimStart && sourceTime <= c.trimEnd) return true;
    }
    return false;
  }
}

class _BarLayout {
  _BarLayout({
    required this.group,
    required this.xStart,
    required this.xEndNatural,
    required this.enabled,
  });

  final KeystrokeGroup group;
  final double xStart;
  final double xEndNatural;
  final bool enabled;
}

/// A single shortcut bar: a rounded rect that fades left→right (mirroring the
/// badge's on-screen fade), with the label pinned at the left (the press
/// instant). Blue rim when enabled, dim grey when disabled; lifts on hover.
class _ShortcutBar extends StatelessWidget {
  const _ShortcutBar({
    required this.label,
    required this.count,
    required this.enabled,
    required this.hovered,
  });

  final String label;
  final int count;
  final bool enabled;
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    final border = enabled
        ? (hovered ? const Color(0xFF7FB0FF) : const Color(0xFF4F8FF5))
        : const Color(0x33FFFFFF);
    final fillLeft =
        enabled ? const Color(0xF02A2A48) : const Color(0xE61A1A24);
    final fillRight =
        enabled ? const Color(0x332A2A48) : const Color(0x221A1A24);
    final textColor = enabled ? Colors.white : Colors.white60;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [fillLeft, fillRight],
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border, width: 1.5),
        boxShadow: hovered
            ? const [
                BoxShadow(
                  color: Color(0x80000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: label),
                if (count > 1)
                  TextSpan(
                    text: '  ×$count',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: textColor.withValues(alpha: 0.6),
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.clip,
            softWrap: false,
            style: TextStyle(
              color: textColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}
