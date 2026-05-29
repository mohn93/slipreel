import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../../onboarding/tip_anchor.dart';
import '../../onboarding/tips_controller.dart';
import 'mic_status.dart';
import 'spring_hover_button.dart';

/// The selectable source modes on the bar. `device` is shown but disabled.
enum BarSourceMode { display, window, area, device }

/// Shared height for the labelled bar controls so their hover containers all
/// line up (modes are icon-over-label; A/V are icon-beside-label).
const double _kBarButtonHeight = 56;

/// Fixed width for the mic chip so the bar doesn't resize as the device label
/// changes — long labels ellipsize, the icon and chevron stay anchored.
const double _kMicChipWidth = 160;

/// The compact floating control bar: close, source modes, disabled A/V
/// placeholders, and a gear button that opens a NATIVE menu. There are
/// intentionally no Flutter Tooltips/dropdowns here — Flutter overlays cannot
/// escape the tiny borderless window and would clip. Pure presentation; all
/// actions are callbacks.
class RecordingBar extends StatelessWidget {
  const RecordingBar({
    super.key,
    required this.onPickMode,
    required this.onClose,
    required this.onGearTap,
    required this.onDragStart,
    this.microphone,
    required this.onMicTap,
    this.systemAudio,
    required this.onSystemAudioTap,
    this.contentKey,
    this.micLevelStream,
  });

  final void Function(BarSourceMode mode) onPickMode;
  final VoidCallback onClose;
  final VoidCallback onGearTap;

  /// Fired when the user begins dragging a non-button area — used to start a
  /// native window drag so the borderless bar can be repositioned.
  final VoidCallback onDragStart;

  /// Current microphone selection (null = off). Renders the mic control state.
  final MicrophoneConfig? microphone;

  /// Fired when the mic control is tapped (opens the native mic menu).
  final VoidCallback onMicTap;

  /// Current system-audio selection (null = off).
  final SystemAudioConfig? systemAudio;

  /// Fired when the system-audio control is tapped (opens the native menu).
  final VoidCallback onSystemAudioTap;

  /// Attached to the inner content [Row] so the host can measure its intrinsic
  /// width and resize the (variable-width) bar window to hug the content.
  final Key? contentKey;

  /// Live mic level (0..1) stream; when non-null a meter is shown under the mic
  /// control. Null when not monitoring.
  final Stream<double>? micLevelStream;

  @override
  Widget build(BuildContext context) {
    // Fills the whole (borderless) window edge-to-edge with the bar colour;
    // the native window rounds its corners via a layer mask and supplies the
    // drop shadow. The pan gesture lets the user drag the borderless window
    // from any non-button area (buttons still receive their taps).
    return GestureDetector(
      onPanStart: (_) => onDragStart(),
      child: Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFF2C2C30),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Center(
        child: Row(
          key: contentKey,
          mainAxisSize: MainAxisSize.min,
          children: [
            _CircleButton(
              barKey: const Key('bar-close'),
              // Material's close has heavier strokes than Lucide's hairline x,
              // which reads better in the tiny inverted chip.
              icon: Icons.close_rounded,
              onPressed: onClose,
            ),
            const _Divider(),
            TipAnchor(
              tipId: TipId.barModePicker,
              child: _Mode(
                icon: LucideIcons.monitor,
                label: 'Display',
                onTap: () => onPickMode(BarSourceMode.display),
              ),
            ),
            _Mode(
              icon: LucideIcons.appWindowMac,
              label: 'Window',
              onTap: () => onPickMode(BarSourceMode.window),
            ),
            _Mode(
              icon: LucideIcons.scan,
              label: 'Area',
              onTap: () => onPickMode(BarSourceMode.area),
            ),
            const _Mode(icon: LucideIcons.smartphone, label: 'Device'),
            const _Divider(),
            const _AvPlaceholder(icon: LucideIcons.videoOff, label: 'No camera'),
            _MicControl(
                microphone: microphone,
                onTap: onMicTap,
                levelStream: micLevelStream),
            _SystemAudioControl(
                systemAudio: systemAudio, onTap: onSystemAudioTap),
            const _Divider(),
            _GearButton(onTap: onGearTap),
          ],
        ),
      ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 34,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: Colors.white.withValues(alpha: 0.10),
      );
}

class _Mode extends StatelessWidget {
  const _Mode({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final iconColor =
        disabled ? const Color(0xFF6E6E76) : const Color(0xFFE9E9EC);
    // Labels read subtler than the icons.
    final labelColor = disabled
        ? const Color(0xFF6E6E76)
        : Colors.white.withValues(alpha: 0.55);
    return SpringHoverButton(
      onTap: onTap,
      // Fixed width so all four mode tiles (and their hover pills) are equal,
      // regardless of label length.
      child: SizedBox(
        width: 58,
        height: _kBarButtonHeight,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: iconColor),
              const SizedBox(height: 2),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: TextStyle(fontSize: 10, color: labelColor)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AvPlaceholder extends StatefulWidget {
  const _AvPlaceholder({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  State<_AvPlaceholder> createState() => _AvPlaceholderState();
}

class _AvPlaceholderState extends State<_AvPlaceholder> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return SpringHoverButton(
      onTap: null,
      onHoverChanged: (h) => setState(() => _hover = h),
      child: SizedBox(
        height: _kBarButtonHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Center(
            // On hover the icon + label animate from the inactive grey up to
            // the active bright colour.
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: _hover ? 1.0 : 0.0),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              builder: (context, t, _) {
                final color = Color.lerp(
                    const Color(0xFF6E6E76), const Color(0xFFE9E9EC), t)!;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, size: 22, color: color),
                    const SizedBox(width: 6),
                    Text(widget.label,
                        style: TextStyle(fontSize: 12, color: color)),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Live microphone control: icon + (truncated) device name + chevron. Greyed
/// when off. Tapping opens the native mic menu via [onTap].
/// When [levelStream] is non-null, a [MicLevelMeter] is rendered inside the
/// chip's container, pinned to the bottom — the chip's icon/label stay put
/// and the bar height does NOT grow.
class _MicControl extends StatefulWidget {
  const _MicControl({
    required this.microphone,
    required this.onTap,
    this.levelStream,
  });

  final MicrophoneConfig? microphone;
  final VoidCallback onTap;
  final Stream<double>? levelStream;

  @override
  State<_MicControl> createState() => _MicControlState();
}

class _MicControlState extends State<_MicControl> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.microphone != null;
    final label = on ? widget.microphone!.deviceLabel : 'No microphone';
    // Active when a mic is selected, or while hovered — the icon/label animate
    // from the inactive grey to the active bright colour.
    final active = on || _hover;
    return SpringHoverButton(
      key: const Key('bar-mic'),
      onTap: widget.onTap,
      onHoverChanged: (h) => setState(() => _hover = h),
      child: SizedBox(
        width: _kMicChipWidth,
        height: _kBarButtonHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Stack(
            children: [
              Positioned.fill(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: active ? 1.0 : 0.0),
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  builder: (context, t, _) {
                    final color = Color.lerp(
                        const Color(0xFF6E6E76), const Color(0xFFE9E9EC), t)!;
                    return Row(
                      children: [
                        Icon(on ? LucideIcons.mic : LucideIcons.micOff,
                            size: 22, color: color),
                        const SizedBox(width: 6),
                        // Left-aligned label fills the remaining fixed width and
                        // ellipsizes; the leading icon never shifts.
                        Expanded(
                          child: Text(label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              textAlign: TextAlign.left,
                              style: TextStyle(fontSize: 12, color: color)),
                        ),
                        const SizedBox(width: 2),
                        const Icon(LucideIcons.chevronDown,
                            size: 13, color: Color(0xFF7E7E86)),
                      ],
                    );
                  },
                ),
              ),
              if (widget.levelStream != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 6,
                  child: MicStatus(levelStream: widget.levelStream!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// System-audio control: speaker icon + label + chevron, mirroring [_MicControl]
/// (fixed-width chip, hover-brighten). Greyed when off. Tapping opens the native
/// system-audio menu via [onTap].
class _SystemAudioControl extends StatefulWidget {
  const _SystemAudioControl({required this.systemAudio, required this.onTap});

  final SystemAudioConfig? systemAudio;
  final VoidCallback onTap;

  @override
  State<_SystemAudioControl> createState() => _SystemAudioControlState();
}

class _SystemAudioControlState extends State<_SystemAudioControl> {
  bool _hover = false;

  String get _label {
    final cfg = widget.systemAudio;
    if (cfg == null) return 'No system audio';
    switch (cfg.mode) {
      case SystemAudioMode.allApps:
        return 'System audio';
      case SystemAudioMode.selectedApps:
        final n = cfg.bundleIds.length;
        return n == 1 ? '1 app' : '$n apps';
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.systemAudio != null;
    final active = on || _hover;
    return SpringHoverButton(
      key: const Key('bar-system-audio'),
      onTap: widget.onTap,
      onHoverChanged: (h) => setState(() => _hover = h),
      child: SizedBox(
        width: _kMicChipWidth,
        height: _kBarButtonHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: active ? 1.0 : 0.0),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            builder: (context, t, _) {
              final color = Color.lerp(
                  const Color(0xFF6E6E76), const Color(0xFFE9E9EC), t)!;
              return Row(
                children: [
                  Icon(on ? LucideIcons.volume2 : LucideIcons.volumeOff,
                      size: 22, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        textAlign: TextAlign.left,
                        style: TextStyle(fontSize: 12, color: color)),
                  ),
                  const SizedBox(width: 2),
                  const Icon(LucideIcons.chevronDown,
                      size: 13, color: Color(0xFF7E7E86)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Test-only public wrapper around the private [_SystemAudioControl].
@visibleForTesting
class SystemAudioControlForTest extends StatelessWidget {
  const SystemAudioControlForTest(
      {super.key, this.systemAudio, required this.onTap});
  final SystemAudioConfig? systemAudio;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) =>
      _SystemAudioControl(systemAudio: systemAudio, onTap: onTap);
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.barKey, required this.icon, required this.onPressed});

  final Key barKey;
  // Kept for API symmetry with the original `_CircleButton`; the close button
  // now uses a hand-painted heavy X instead of a font glyph because Material's
  // `weight:` axis is a no-op on the non-variable MaterialIcons font shipped
  // with Flutter.
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SpringHoverButton(
      key: barKey,
      onTap: onPressed,
      borderRadius: 11,
      child: SizedBox(
        width: 46,
        height: _kBarButtonHeight,
        child: Center(
          child: Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(
              color: Color(0xFFE9E9EC),
              shape: BoxShape.circle,
            ),
            child: const CustomPaint(painter: _HeavyXPainter()),
          ),
        ),
      ),
    );
  }
}

/// Draws a chunky "×" with rounded caps. Stroke is ~22% of the box edge so
/// the X reads bold inside the small 22px chip without overflowing.
class _HeavyXPainter extends CustomPainter {
  const _HeavyXPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF2C2C30)
      ..strokeWidth = size.shortestSide * 0.08
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    // Inset so the rounded caps don't kiss the circle's edge.
    final inset = size.shortestSide * 0.30;
    final r = Rect.fromLTRB(
      inset, inset, size.width - inset, size.height - inset,
    );
    canvas.drawLine(r.topLeft, r.bottomRight, paint);
    canvas.drawLine(r.topRight, r.bottomLeft, paint);
  }

  @override
  bool shouldRepaint(_HeavyXPainter oldDelegate) => false;
}

class _GearButton extends StatelessWidget {
  const _GearButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Subtler than the other icons, with a small dropdown chevron beside it.
    return SpringHoverButton(
      key: const Key('bar-gear'),
      onTap: onTap,
      borderRadius: 11,
      child: const SizedBox(
        width: 46,
        height: _kBarButtonHeight,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.settings, color: Color(0xFF7E7E86), size: 22),
              SizedBox(width: 1),
              Icon(LucideIcons.chevronDown, color: Color(0xFF7E7E86), size: 13),
            ],
          ),
        ),
      ),
    );
  }
}
