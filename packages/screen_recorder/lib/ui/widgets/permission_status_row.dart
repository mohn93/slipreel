import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// A label + subtitle row with a status-driven action: a check when granted,
/// "Open System Settings" when denied/restricted, "Grant" otherwise. Shared by
/// first-run onboarding and the Settings permissions section.
class PermissionStatusRow extends StatelessWidget {
  const PermissionStatusRow({
    super.key,
    required this.kind,
    required this.label,
    required this.subtitle,
    required this.status,
    required this.onGrant,
    required this.onOpenSettings,
  });

  final PermissionKind kind;
  final String label;
  final String subtitle;
  final PermissionStatus status;
  final VoidCallback onGrant;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleMedium),
                Text(subtitle,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.white60)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _action(),
        ],
      ),
    );
  }

  Widget _action() {
    switch (status) {
      case PermissionStatus.granted:
        return const Icon(Icons.check_circle, color: Colors.greenAccent);
      case PermissionStatus.denied:
      case PermissionStatus.restricted:
        return OutlinedButton(
          onPressed: onOpenSettings,
          child: const Text('Open System Settings'),
        );
      case PermissionStatus.notDetermined:
      case PermissionStatus.unsupported:
        return FilledButton.tonal(
          onPressed: onGrant,
          child: const Text('Grant'),
        );
    }
  }
}
