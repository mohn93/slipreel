import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

class PermissionDeniedSheet extends StatefulWidget {
  const PermissionDeniedSheet({super.key, required this.kind});
  final PermissionKind kind;

  static const _urls = {
    PermissionKind.screenRecording:
        'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
    PermissionKind.microphone:
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
    PermissionKind.accessibility:
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
    PermissionKind.camera:
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera',
  };

  static const _titles = {
    PermissionKind.screenRecording: 'Screen Recording permission required',
    PermissionKind.microphone: 'Microphone permission required',
    PermissionKind.accessibility: 'Accessibility permission required',
    PermissionKind.camera: 'Camera permission required',
  };

  static const _bodies = {
    PermissionKind.screenRecording:
        'Slipreel needs Screen Recording access in System Settings to capture your screen.',
    PermissionKind.microphone:
        'Slipreel needs Microphone access in System Settings to record your voice.',
    PermissionKind.accessibility:
        'Slipreel needs Accessibility access in System Settings to track clicks.',
    PermissionKind.camera:
        'Slipreel needs Camera access in System Settings to record your webcam.',
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
  State<PermissionDeniedSheet> createState() => _PermissionDeniedSheetState();
}

class _PermissionDeniedSheetState extends State<PermissionDeniedSheet> {
  String? _error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(PermissionDeniedSheet._titles[widget.kind]!,
                style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(PermissionDeniedSheet._bodies[widget.kind]!,
                style: theme.textTheme.bodyMedium),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () async {
                bool ok = false;
                try {
                  ok = await launchUrl(
                      Uri.parse(PermissionDeniedSheet._urls[widget.kind]!));
                } on PlatformException catch (_) {
                  ok = false;
                } catch (_) {
                  ok = false;
                }
                if (!mounted) return;
                if (ok) {
                  Navigator.of(context).pop();
                } else {
                  setState(() {
                    _error =
                        "Couldn't open System Settings. Open Privacy & Security manually.";
                  });
                }
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

