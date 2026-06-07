import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/keystroke_group.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/models/keystroke_recording.dart';

/// On-canvas keystroke badge overlay.
///
/// Placed inside the PlaybackCanvas SizedBox (in canvas-pixel space) so
/// it is naturally scaled by the outer FittedBox. Reads the
/// [keystrokeRecording] at the given [position] and renders floating keycap
/// badges for the events in the current fade window that pass the display
/// filter (real shortcuts always; single nav/action keys when opted in;
/// plain typing never). Rebuilt every frame via the parent's AnimatedBuilder.
///
/// Uses an IgnorePointer wrapper so hit-testing falls through to the
/// video player controls below.
class KeystrokeOverlay extends StatelessWidget {
  const KeystrokeOverlay({
    super.key,
    required this.position,
    required this.keystrokeRecording,
    required this.settings,
    required this.canvasSize,
  });

  final Duration position;
  final KeystrokeRecording keystrokeRecording;
  final KeystrokeOverlaySettings settings;
  final Size canvasSize;

  // How long the fade-in takes.
  static const _fadeInSecs = 0.08;

  // How much of the tail is a fade-out.
  static const _fadeOutSecs = 0.35;

  // Duration of the shrink→grow "click" pulse applied on each press.
  static const _pulseSecs = 0.24;

  // Extra lookback beyond the fade window so a repeat burst that started
  // earlier still coalesces with a stable ×N count.
  static const _burstLookbackMicros = 6000000;

  // Max recent distinct shortcuts shown when stacking (non-single-box).
  static const _maxStack = 3;

  @override
  Widget build(BuildContext context) {
    final nowMicros = position.inMicroseconds;
    final windowMicros = (settings.fadeSecs * 1e6).round();
    final startMicros = nowMicros - windowMicros - _burstLookbackMicros;

    final raw = keystrokeRecording.eventsInRange(startMicros, nowMicros);
    if (raw.isEmpty) return const SizedBox.shrink();

    // Filter to displayable + user-enabled events, then coalesce consecutive
    // repeats of the same shortcut into one group (one pulsing box).
    final filtered = raw
        .where((e) =>
            settings.shouldDisplay(e.kind) &&
            settings.isKeyEnabled(e.timestampMicros))
        .toList();
    if (filtered.isEmpty) return const SizedBox.shrink();
    final groups = coalesceKeystrokes(filtered);

    // Walk newest-first; keep groups whose latest press is still inside the
    // fade window. One in single-box mode, otherwise a short stack.
    final badges = <Widget>[];
    for (var i = groups.length - 1; i >= 0; i--) {
      final g = groups[i];
      final elapsed = (nowMicros - g.lastMicros) / 1e6;
      if (elapsed * 1e6 > windowMicros) break; // older groups are older still
      final opacity = _opacityFor(elapsed, settings.fadeSecs);
      if (opacity <= 0) continue;

      badges.add(
        Opacity(
          opacity: opacity,
          child: Transform.scale(
            // Pulse is a pure function of time-since-last-press so the
            // editor preview and the export render frame-for-frame alike.
            scale: _pressPulse(elapsed / _pulseSecs),
            child: KeystrokeKeycap(
              label: g.label,
              count: g.count,
              scale: settings.labelScale,
            ),
          ),
        ),
      );
      if (settings.singleBox || badges.length >= _maxStack) break;
    }

    if (badges.isEmpty) return const SizedBox.shrink();

    return IgnorePointer(
      child: SizedBox(
        width: canvasSize.width,
        height: canvasSize.height,
        child: Align(
          alignment: _alignmentFor(settings.position),
          child: Padding(
            padding: EdgeInsets.only(
              bottom: canvasSize.height * 0.06,
              left: settings.position == KeystrokePosition.bottomLeft
                  ? canvasSize.width * 0.04
                  : 0,
              right: settings.position == KeystrokePosition.bottomRight
                  ? canvasSize.width * 0.04
                  : 0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: _crossAxisFor(settings.position),
              children: badges
                  .map((b) => Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: b,
                      ))
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  static double _opacityFor(double elapsed, double fadeSecs) {
    if (elapsed < 0) return 0;
    if (elapsed < _fadeInSecs) return elapsed / _fadeInSecs;
    final fadeOutStart = fadeSecs - _fadeOutSecs;
    if (elapsed < fadeOutStart) return 1.0;
    if (elapsed < fadeSecs) {
      return 1.0 - (elapsed - fadeOutStart) / _fadeOutSecs;
    }
    return 0;
  }

  /// Scale multiplier for a press [t] of the way through the pulse window
  /// (0..1). Quick squash (smaller) then springs back past 1.0 (bigger) and
  /// settles — reads as a click. Returns 1.0 outside the window.
  static double _pressPulse(double t) {
    if (t <= 0 || t >= 1) return 1.0;
    const shrink = 0.16;
    if (t < 0.32) {
      return 1.0 - shrink * Curves.easeOut.transform(t / 0.32);
    }
    final u = (t - 0.32) / 0.68;
    return (1.0 - shrink) + shrink * Curves.easeOutBack.transform(u);
  }

  static Alignment _alignmentFor(KeystrokePosition pos) => switch (pos) {
    KeystrokePosition.centerBottom => Alignment.bottomCenter,
    KeystrokePosition.bottomLeft   => Alignment.bottomLeft,
    KeystrokePosition.bottomRight  => Alignment.bottomRight,
  };

  static CrossAxisAlignment _crossAxisFor(KeystrokePosition pos) =>
      switch (pos) {
        KeystrokePosition.centerBottom => CrossAxisAlignment.center,
        KeystrokePosition.bottomLeft   => CrossAxisAlignment.start,
        KeystrokePosition.bottomRight  => CrossAxisAlignment.end,
      };
}

/// A single keycap-styled badge for a captured keystroke label.
///
/// Shared between the on-canvas [KeystrokeOverlay] and the editor's
/// shortcuts timeline lane so both look identical. Sizes are uniform for
/// short labels (single glyphs get a square-ish minimum width) and grow
/// for wider labels like "Space". Everything scales by [scale].
///
/// NOTE: the body must NOT use `Container(alignment:)` — a Container with a
/// non-null alignment expands to fill its parent's max width, which over the
/// canvas (bounded width) stretched every keycap into a full-width bar. The
/// glyph is centred via [Text.textAlign] + the [ConstrainedBox] minWidth
/// propagating through the padding, so the box stays shrink-wrapped.
class KeystrokeKeycap extends StatelessWidget {
  const KeystrokeKeycap({
    super.key,
    required this.label,
    this.count = 1,
    this.scale = 1.0,
    this.fill = const Color(0xF014141C),
    this.border = const Color(0xB36A6EA0),
    this.textColor = Colors.white,
  });

  final String label;

  /// Number of coalesced repeats. When > 1 a small "×N" multiplier is shown.
  final int count;

  /// Multiplier applied to every metric. 1.0 is the base size.
  final double scale;

  /// Keycap body fill. Defaults to a near-black cool charcoal for
  /// over-video use.
  final Color fill;

  /// Keycap border / rim colour — a soft muted indigo.
  final Color border;

  /// Label text colour.
  final Color textColor;

  // Base metrics at scale 1.0.
  static const double _baseFontSize = 30;
  static const double _baseHPad = 18;
  static const double _baseVPad = 14;
  static const double _baseMinWidth = 76;
  static const double _baseRadius = 18;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: _baseMinWidth * s),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: _baseHPad * s,
          vertical: _baseVPad * s,
        ),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(_baseRadius * s),
          border: Border.all(color: border, width: 2 * s),
          boxShadow: [
            // Soft drop shadow for separation from the video / lane.
            BoxShadow(
              color: const Color(0x59000000),
              blurRadius: 12 * s,
              offset: Offset(0, 4 * s),
            ),
          ],
        ),
        // Single RichText keeps `textAlign: center` + the ConstrainedBox
        // minWidth working (so short labels centre in a uniform box) while
        // letting the ×N multiplier ride along in a smaller, dimmer style.
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: label),
              if (count > 1)
                TextSpan(
                  text: '  ×$count',
                  style: TextStyle(
                    fontSize: _baseFontSize * s * 0.6,
                    fontWeight: FontWeight.w600,
                    color: textColor.withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: textColor,
            fontSize: _baseFontSize * s,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}
