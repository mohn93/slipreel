import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/ui/widgets/permission_denied_sheet.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class PermissionsPage extends ConsumerWidget {
  const PermissionsPage({super.key, required this.onNext});
  final VoidCallback onNext;

  static const _labels = {
    PermissionKind.screenRecording: 'Screen Recording',
    PermissionKind.microphone: 'Microphone',
    PermissionKind.accessibility: 'Accessibility',
  };

  static const _subtitles = {
    PermissionKind.screenRecording: 'Required to capture your screen.',
    PermissionKind.microphone: 'Optional — for voice narration.',
    PermissionKind.accessibility: 'Optional — for richer click tracking.',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(permissionsControllerProvider);
    final screenRecGranted = snap.screenRec == PermissionStatus.granted;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Permissions',
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          for (final kind in PermissionKind.values)
            _PermissionRow(
              kind: kind,
              label: _labels[kind]!,
              subtitle: _subtitles[kind]!,
              status: snap.byKind[kind] ?? PermissionStatus.unsupported,
              onGrant: () => ref
                  .read(permissionsControllerProvider.notifier)
                  .request(kind),
              onOpenSettings: () =>
                  PermissionDeniedSheet.show(context, kind),
            ),
          const Spacer(),
          FilledButton(
            onPressed: screenRecGranted ? onNext : null,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Continue'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
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
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Colors.white60)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _RowAction(
              status: status,
              onGrant: onGrant,
              onOpenSettings: onOpenSettings),
        ],
      ),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.status,
    required this.onGrant,
    required this.onOpenSettings,
  });
  final PermissionStatus status;
  final VoidCallback onGrant;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
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
