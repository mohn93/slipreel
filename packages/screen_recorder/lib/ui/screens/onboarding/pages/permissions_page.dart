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
    PermissionKind.camera: 'Camera',
    PermissionKind.microphone: 'Microphone',
    PermissionKind.accessibility: 'Accessibility',
  };

  static const _subtitles = {
    PermissionKind.screenRecording: 'Required to capture your screen.',
    PermissionKind.camera: 'Optional — for webcam / facecam.',
    PermissionKind.microphone: 'Optional — for voice narration.',
    PermissionKind.accessibility: 'Optional — for richer click tracking.',
  };

  static const _icons = {
    PermissionKind.screenRecording: Icons.desktop_windows_outlined,
    PermissionKind.camera: Icons.videocam_outlined,
    PermissionKind.microphone: Icons.mic_none_outlined,
    PermissionKind.accessibility: Icons.keyboard_outlined,
  };

  /// Permissions surfaced during first-run onboarding, in the reference order.
  /// Camera is shown but optional — only Screen Recording gates Confirm.
  static const _onboardingKinds = [
    PermissionKind.screenRecording,
    PermissionKind.camera,
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
              icon: _icons[kind]!,
              label: _labels[kind]!,
              subtitle: _subtitles[kind]!,
              status: snap.byKind[kind] ?? PermissionStatus.unsupported,
              // Screen Recording reads back as `denied` until granted (binary
              // preflight), so let its row fire the request directly —
              // CGRequestScreenCaptureAccess prompts and self-registers the app
              // in the Screen Recording list. The optional permissions keep the
              // passive Open-Settings path on a real denial.
              canRequestWhenDenied: kind == PermissionKind.screenRecording,
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
              child: Text('Confirm'),
            ),
          ),
        ],
      ),
    );
  }
}
