import 'package:flutter/material.dart';

/// The selectable source modes on the bar. `device` is shown but disabled.
enum BarSourceMode { display, window, area, device }

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
  });

  final void Function(BarSourceMode mode) onPickMode;
  final VoidCallback onClose;
  final VoidCallback onGearTap;

  @override
  Widget build(BuildContext context) {
    // Fills the whole (borderless) window edge-to-edge with the bar colour;
    // the native window rounds its corners via a layer mask and supplies the
    // drop shadow.
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFF2C2C30),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CircleButton(
              key: const Key('bar-close'),
              icon: Icons.close,
              onPressed: onClose,
            ),
            const _Divider(),
            _Mode(
              icon: Icons.desktop_windows_outlined,
              label: 'Display',
              onTap: () => onPickMode(BarSourceMode.display),
            ),
            _Mode(
              icon: Icons.web_asset,
              label: 'Window',
              onTap: () => onPickMode(BarSourceMode.window),
            ),
            _Mode(
              icon: Icons.crop_free,
              label: 'Area',
              onTap: () => onPickMode(BarSourceMode.area),
            ),
            const _Mode(icon: Icons.phone_iphone, label: 'Device'),
            const _Divider(),
            const _AvPlaceholder(icon: Icons.videocam_off_outlined, label: 'No camera'),
            const _AvPlaceholder(icon: Icons.mic_off_outlined, label: 'No microphone'),
            const _AvPlaceholder(icon: Icons.volume_off_outlined, label: 'No system audio'),
            const _Divider(),
            _GearButton(onTap: onGearTap),
          ],
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF6E6E76)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6E6E76))),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({super.key, required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      customBorder: const CircleBorder(),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 16, color: const Color(0xFFE9E9EC)),
      ),
    );
  }
}

class _GearButton extends StatelessWidget {
  const _GearButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('bar-gear'),
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: const SizedBox(
        width: 32,
        height: 32,
        child: Icon(Icons.settings_outlined, color: Color(0xFFD6D6DA), size: 20),
      ),
    );
  }
}
