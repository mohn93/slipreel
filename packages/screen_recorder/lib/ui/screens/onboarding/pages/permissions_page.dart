import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/ui/widgets/permission_denied_sheet.dart';
import 'package:screen_recorder/ui/widgets/permission_status_row.dart';
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

  /// Permissions surfaced during first-run onboarding. Camera is intentionally
  /// excluded — it's optional and requested on demand when the user picks a
  /// camera device, not a first-run gate.
  static const _onboardingKinds = [
    PermissionKind.screenRecording,
    PermissionKind.microphone,
    PermissionKind.accessibility,
  ];

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
          for (final kind in _onboardingKinds)
            PermissionStatusRow(
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
