import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class PermissionCta extends StatelessWidget {
  const PermissionCta({super.key, required this.onRetry});

  final VoidCallback onRetry;

  static final Uri _settingsUri = Uri.parse(
    'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
  );

  Future<void> _openSettings() async {
    if (await canLaunchUrl(_settingsUri)) {
      await launchUrl(_settingsUri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48, color: Colors.white54),
            const SizedBox(height: 16),
            const Text(
              'ScreenFlow needs Screen Recording permission',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Grant access in System Settings, then tap retry.',
              style: TextStyle(color: Colors.white60, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: _openSettings,
                  child: const Text('Open System Settings'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
