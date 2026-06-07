import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/models/keystroke_recording.dart';

/// On-canvas keystroke badge overlay.
///
/// Placed inside the PlaybackCanvas SizedBox (in canvas-pixel space) so
/// it is naturally scaled by the outer FittedBox. Reads the
/// [keystrokeRecording] at the given [position] and renders floating pill
/// badges for all events in the current fade window. Rebuilt every frame
/// via the parent's AnimatedBuilder.
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

  @override
  Widget build(BuildContext context) {
    final nowMicros = position.inMicroseconds;
    final windowMicros = (settings.fadeSecs * 1e6).round();
    final startMicros = nowMicros - windowMicros;

    final events = keystrokeRecording.eventsInRange(startMicros, nowMicros);
    if (events.isEmpty) return const SizedBox.shrink();

    // Build badge widgets, newest first (reversed).
    final badges = <Widget>[];
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      final elapsed = (nowMicros - e.timestampMicros) / 1e6;
      final opacity = _opacityFor(elapsed, settings.fadeSecs);
      if (opacity <= 0) continue;

      badges.add(
        Opacity(
          opacity: opacity,
          child: _KeystrokeBadge(
            label: e.label,
            size: settings.size,
          ),
        ),
      );
      if (badges.length >= 3) break;
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
                        padding: const EdgeInsets.only(top: 6),
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

class _KeystrokeBadge extends StatelessWidget {
  const _KeystrokeBadge({required this.label, required this.size});

  final String label;
  final KeystrokeSize size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: size.horizontalPadding,
        vertical: size.verticalPadding,
      ),
      decoration: BoxDecoration(
        color: const Color(0xCC1A1A2E),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(
          color: Colors.white.withAlpha(51),
          width: 1,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: size.fontSize,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
