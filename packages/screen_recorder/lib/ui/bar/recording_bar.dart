import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

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
              icon: LucideIcons.x,
              onPressed: onClose,
            ),
            const _Divider(),
            _Mode(
              icon: LucideIcons.monitor,
              label: 'Display',
              onTap: () => onPickMode(BarSourceMode.display),
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
            const _AvPlaceholder(icon: LucideIcons.volumeOff, label: 'No system audio'),
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

class _AvPlaceholder extends StatelessWidget {
  const _AvPlaceholder({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SpringHoverButton(
      onTap: null,
      child: SizedBox(
        height: _kBarButtonHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: const Color(0xFF6E6E76)),
                const SizedBox(width: 6),
                Text(label,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6E6E76))),
              ],
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
class _MicControl extends StatelessWidget {
  const _MicControl({
    required this.microphone,
    required this.onTap,
    this.levelStream,
  });

  final MicrophoneConfig? microphone;
  final VoidCallback onTap;
  final Stream<double>? levelStream;

  @override
  Widget build(BuildContext context) {
    final on = microphone != null;
    final label = on ? microphone!.deviceLabel : 'No microphone';
    final iconColor = on ? const Color(0xFFE9E9EC) : const Color(0xFF6E6E76);
    final textColor = on ? const Color(0xFFE9E9EC) : const Color(0xFF6E6E76);
    final chip = SpringHoverButton(
      key: const Key('bar-mic'),
      onTap: onTap,
      child: SizedBox(
        width: _kMicChipWidth,
        height: _kBarButtonHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Stack(
            children: [
              Positioned.fill(
                child: Row(
                  children: [
                    Icon(on ? LucideIcons.mic : LucideIcons.micOff,
                        size: 22, color: iconColor),
                    const SizedBox(width: 6),
                    // Left-aligned label fills the remaining fixed width and
                    // ellipsizes; the leading icon never shifts with label length.
                    Expanded(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          textAlign: TextAlign.left,
                          style: TextStyle(fontSize: 12, color: textColor)),
                    ),
                    const SizedBox(width: 2),
                    const Icon(LucideIcons.chevronDown,
                        size: 13, color: Color(0xFF7E7E86)),
                  ],
                ),
              ),
              if (levelStream != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 6,
                  child: MicStatus(levelStream: levelStream!),
                ),
            ],
          ),
        ),
      ),
    );
    return chip;
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.barKey, required this.icon, required this.onPressed});

  final Key barKey;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // Square hover container (like the other buttons), with an inverted chip:
    // light fill, dark glyph.
    return SpringHoverButton(
      key: barKey,
      onTap: onPressed,
      borderRadius: 11,
      child: SizedBox(
        width: 46,
        height: _kBarButtonHeight,
        child: Center(
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: const Color(0xFFE9E9EC),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 16, color: const Color(0xFF2C2C30)),
          ),
        ),
      ),
    );
  }
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
