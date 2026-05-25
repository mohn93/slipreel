import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'spring_hover_button.dart';

/// The selectable source modes on the bar. `device` is shown but disabled.
enum BarSourceMode { display, window, area, device }

/// Shared height for the labelled bar controls so their hover containers all
/// line up (modes are icon-over-label; A/V are icon-beside-label).
const double _kBarButtonHeight = 50;

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
  });

  final void Function(BarSourceMode mode) onPickMode;
  final VoidCallback onClose;
  final VoidCallback onGearTap;

  /// Fired when the user begins dragging a non-button area — used to start a
  /// native window drag so the borderless bar can be repositioned.
  final VoidCallback onDragStart;

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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Center(
        child: Row(
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
            const _AvPlaceholder(icon: LucideIcons.micOff, label: 'No microphone'),
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
    final color = disabled ? const Color(0xFF6E6E76) : const Color(0xFFE9E9EC);
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
              Icon(icon, size: 18, color: color),
              const SizedBox(height: 3),
              Text(label, style: TextStyle(fontSize: 11, color: color)),
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
                Icon(icon, size: 18, color: const Color(0xFF6E6E76)),
                const SizedBox(width: 6),
                Text(label,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF6E6E76))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.barKey, required this.icon, required this.onPressed});

  final Key barKey;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SpringHoverButton(
      key: barKey,
      onTap: onPressed,
      borderRadius: 15,
      child: SizedBox(
        width: 30,
        height: 30,
        child: Icon(icon, size: 18, color: const Color(0xFFE9E9EC)),
      ),
    );
  }
}

class _GearButton extends StatelessWidget {
  const _GearButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SpringHoverButton(
      key: const Key('bar-gear'),
      onTap: onTap,
      borderRadius: 16,
      child: const SizedBox(
        width: 32,
        height: 32,
        child: Icon(LucideIcons.settings, color: Color(0xFFD6D6DA), size: 18),
      ),
    );
  }
}
