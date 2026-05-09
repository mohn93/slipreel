import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

/// A non-blocking banner shown above the recording source picker when
/// the host process is missing the macOS Accessibility permission.
///
/// Recording itself works fine without it, but cursor-state detection
/// (capturing the I-beam over text fields, the pointing hand over
/// links, etc.) needs Accessibility because that's the only public
/// API that can report the cursor's appearance across other apps.
///
/// The banner is dismissible-by-granting: once the permission is
/// granted and the app is relaunched, the parent screen's polled
/// trust state flips and this widget renders nothing.
class AccessibilityNotice extends StatefulWidget {
  const AccessibilityNotice({super.key});

  @override
  State<AccessibilityNotice> createState() => _AccessibilityNoticeState();
}

class _AccessibilityNoticeState extends State<AccessibilityNotice>
    with WidgetsBindingObserver {
  bool? _trusted;

  static final Uri _settingsUri = Uri.parse(
    // Apple deep-link to the Accessibility section of Privacy & Security.
    'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-poll trust on resume — the user likely flipped the toggle in
    // System Settings while we were backgrounded. No live update from
    // macOS itself; polling on resume is the recommended pattern.
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    try {
      final trusted =
          await ScreenRecorderPlatform.instance.isAccessibilityTrusted();
      if (!mounted) return;
      setState(() => _trusted = trusted);
    } catch (_) {
      // Plugin not available (tests, non-macOS) — hide the banner.
      if (!mounted) return;
      setState(() => _trusted = true);
    }
  }

  Future<void> _grant() async {
    // Show the system prompt first — this lights up the
    // "Accessibility" pane in System Settings on first run. On
    // subsequent invocations macOS may suppress the prompt, so we
    // also offer to deep-link the user there directly.
    try {
      await ScreenRecorderPlatform.instance.requestAccessibilityPermission();
    } catch (_) {
      // Best-effort; fall through to deep-linking the settings pane.
    }
    if (await canLaunchUrl(_settingsUri)) {
      await launchUrl(_settingsUri);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_trusted ?? true) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2533),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF6C63FF).withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.accessibility_new,
              color: Color(0xFF6C63FF), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enable cursor-aware recording',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Grant Accessibility permission so ScreenFlow can capture '
                  'cursor changes — I-beam over text, pointing hand over '
                  'links, resize handles, etc. Recording works without it, '
                  'but the editor will only show the default arrow.',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'macOS requires a relaunch after granting permission.',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 11.5,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _grant,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF6C63FF),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                      child: const Text('Open Accessibility settings'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _refresh,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                      child: const Text('Re-check'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
