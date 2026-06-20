import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../theme/app_palette.dart';

/// Modal that lists iPhone/iPad devices connected over USB so the user can
/// pick one to record. Returns the chosen [DeviceSource], or `null` if the
/// sheet was dismissed.
///
/// Styled to match the app's dark surfaces. It reads [AppPalette] from the
/// nearest theme when present and falls back to [AppPalette.midnight]
/// constants otherwise, so it renders correctly even without an AppPalette
/// ancestor (e.g. in widget tests).
class DevicePickerOverlay extends StatelessWidget {
  const DevicePickerOverlay._({required this.devices});

  final List<DeviceSource> devices;

  /// Shows the picker and resolves to the selected device, or `null`.
  static Future<DeviceSource?> show(
    BuildContext context, {
    required List<DeviceSource> devices,
  }) {
    return showDialog<DeviceSource>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => DevicePickerOverlay._(devices: devices),
    );
  }

  AppPalette _palette(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? AppPalette.midnight;

  @override
  Widget build(BuildContext context) {
    final palette = _palette(context);
    return Dialog(
      backgroundColor: palette.surfaceCard,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text(
                'Record a device',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (devices.isEmpty)
              _EmptyState(palette: palette)
            else
              ...devices.map((d) => _DeviceRow(device: d, palette: palette)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.palette});

  final DeviceSource device;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final icon = device.kind == DeviceKind.tablet
        ? Icons.tablet_mac
        : Icons.smartphone;
    return InkWell(
      onTap: () => Navigator.pop(context, device),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 22, color: palette.textPrimary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                device.name,
                style: TextStyle(color: palette.textPrimary, fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: palette.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.palette});

  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        children: [
          Icon(Icons.usb, size: 32, color: palette.textSecondary),
          const SizedBox(height: 14),
          Text(
            'Connect an iPhone or iPad over USB and tap Trust This Computer.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
