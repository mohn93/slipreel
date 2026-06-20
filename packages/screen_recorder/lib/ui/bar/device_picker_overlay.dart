import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../theme/app_palette.dart';

/// Full-window screen that lists iPhone/iPad devices connected over USB so the
/// user can pick one to record. Pushed through the recording bar's panel-morph
/// (the bar window is only ~68px tall, so a `showDialog` would overflow — this
/// must be shown in the expanded panel window). Pops with the chosen
/// [DeviceSource], or `null` if dismissed/back.
///
/// Reads [AppPalette] from the nearest theme when present, falling back to
/// [AppPalette.midnight] so it renders without an AppPalette ancestor (tests).
class DevicePickerScreen extends StatelessWidget {
  const DevicePickerScreen({super.key, required this.devices});

  final List<DeviceSource> devices;

  AppPalette _palette(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? AppPalette.midnight;

  @override
  Widget build(BuildContext context) {
    final palette = _palette(context);
    return Scaffold(
      backgroundColor: palette.appBackground,
      appBar: AppBar(
        title: const Text('Record a device'),
        backgroundColor: palette.surfaceElevated,
        foregroundColor: palette.textPrimary,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: devices.isEmpty
              ? _EmptyState(palette: palette)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final d in devices)
                      _DeviceRow(device: d, palette: palette),
                  ],
                ),
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
    final icon =
        device.kind == DeviceKind.tablet ? Icons.tablet_mac : Icons.smartphone;
    return InkWell(
      onTap: () => Navigator.pop(context, device),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: palette.surfaceCard,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 24, color: palette.textPrimary),
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
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.usb, size: 40, color: palette.textSecondary),
          const SizedBox(height: 16),
          Text(
            'Connect an iPhone or iPad over USB and tap Trust This Computer.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
