import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

class PermissionDeniedSheet extends StatelessWidget {
  const PermissionDeniedSheet({super.key, required this.kind});
  final PermissionKind kind;

  static const _urls = {
    PermissionKind.screenRecording:
        'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
    PermissionKind.microphone:
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
    PermissionKind.accessibility:
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
  };

  static const _titles = {
    PermissionKind.screenRecording: 'Screen Recording permission required',
    PermissionKind.microphone: 'Microphone permission required',
    PermissionKind.accessibility: 'Accessibility permission required',
  };

  static const _bodies = {
    PermissionKind.screenRecording:
        'Slipreel needs Screen Recording access in System Settings to capture your screen.',
    PermissionKind.microphone:
        'Slipreel needs Microphone access in System Settings to record your voice.',
    PermissionKind.accessibility:
        'Slipreel needs Accessibility access in System Settings to track clicks.',
  };

  static Future<void> show(BuildContext context, PermissionKind kind) {
    return showModalBottomSheet<void>(
      context: context,
      isDismissible: true,
      showDragHandle: true,
      builder: (_) => PermissionDeniedSheet(kind: kind),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_titles[kind]!,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(_bodies[kind]!,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () async {
                final ok = await launchUrl(Uri.parse(_urls[kind]!));
                if (!context.mounted) return;
                if (ok) Navigator.of(context).pop();
              },
              child: const Text('Open System Settings'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}
