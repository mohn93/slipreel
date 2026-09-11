import 'package:screen_recorder/ui/widgets/desktop_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

const Map<PermissionKind, String> _kUrls = {
  PermissionKind.screenRecording:
      'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
  PermissionKind.microphone:
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
  PermissionKind.accessibility:
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
  PermissionKind.camera:
      'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera',
};

const Map<PermissionKind, String> _kTitles = {
  PermissionKind.screenRecording: 'Screen Recording permission required',
  PermissionKind.microphone: 'Microphone permission required',
  PermissionKind.accessibility: 'Accessibility permission required',
  PermissionKind.camera: 'Camera permission required',
};

const Map<PermissionKind, String> _kBodies = {
  PermissionKind.screenRecording:
      'Slipreel needs Screen Recording access to show available screens and windows. Enable it in System Settings, then quit and reopen Slipreel.',
  PermissionKind.microphone:
      'Slipreel needs Microphone access in System Settings to record your voice.',
  PermissionKind.accessibility:
      'Slipreel needs Accessibility access in System Settings to track clicks.',
  // Camera permission backs BOTH the webcam and the iPhone/iPad-over-USB
  // capture paths (an iOS screen device is a video AVCaptureDevice), so keep
  // this copy generic — it's shown from onboarding, settings, and the bar.
  PermissionKind.camera:
      'Slipreel needs Camera access in System Settings to record a webcam or a connected iPhone or iPad.',
};

/// Why Slipreel is asking for macOS Screen Recording access. System audio is
/// authorized through the same TCC category, but needs purpose-specific copy
/// so the permission request does not look unrelated to the speaker control.
enum ScreenRecordingPermissionPurpose { screenCapture, systemAudio }

String _permissionTitle(
  PermissionKind kind,
  ScreenRecordingPermissionPurpose purpose,
) {
  if (kind == PermissionKind.screenRecording &&
      purpose == ScreenRecordingPermissionPurpose.systemAudio) {
    return 'Allow system audio recording';
  }
  return _kTitles[kind]!;
}

String _permissionBody(
  PermissionKind kind,
  ScreenRecordingPermissionPurpose purpose,
) {
  if (kind == PermissionKind.screenRecording &&
      purpose == ScreenRecordingPermissionPurpose.systemAudio) {
    return 'macOS includes system audio access under Screen Recording. Enable '
        'Slipreel in System Settings, then quit and reopen Slipreel.';
  }
  return _kBodies[kind]!;
}

/// Shared inner content for both presentations below. Owns the "open System
/// Settings" launch + the inline-error state. "Not now" (and a successful
/// launch) pop whatever route hosts it — a dialog or a pushed panel
/// route — so the same widget serves both.
class _PermissionDeniedBody extends StatefulWidget {
  const _PermissionDeniedBody({
    required this.kind,
    required this.screenRecordingPurpose,
  });
  final PermissionKind kind;
  final ScreenRecordingPermissionPurpose screenRecordingPurpose;

  @override
  State<_PermissionDeniedBody> createState() => _PermissionDeniedBodyState();
}

class _PermissionDeniedBodyState extends State<_PermissionDeniedBody> {
  String? _error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopDialogHeading(
              title: _permissionTitle(
                widget.kind,
                widget.screenRecordingPurpose,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _permissionBody(widget.kind, widget.screenRecordingPurpose),
              style: theme.textTheme.bodyMedium,
            ),
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
                // Capture before the await so we don't touch `context` across
                // the async gap (the `mounted` guard still protects the pop).
                final navigator = Navigator.of(context);
                bool ok = false;
                try {
                  ok = await launchUrl(Uri.parse(_kUrls[widget.kind]!));
                } on PlatformException catch (_) {
                  ok = false;
                } catch (_) {
                  ok = false;
                }
                if (!mounted) return;
                if (ok) {
                  if (widget.kind == PermissionKind.screenRecording) {
                    // System Settings is a separate process. Ask the native
                    // layer to pin a lightweight guide beside its window so the
                    // user does not lose the next step after this route closes.
                    try {
                      await ScreenRecorderPlatform.instance
                          .showScreenRecordingPermissionGuide();
                    } catch (_) {
                      // Settings still opened successfully; the guide is an
                      // enhancement and must never block the permission flow.
                    }
                    if (!mounted) return;
                  }
                  navigator.pop();
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

/// Centered dialog for full-size windows (onboarding and settings).
///
/// Do NOT use from the recording bar — that window is ~68px tall, so the dialog
/// clips to an empty dark scrim. Use [PermissionDeniedScreen] via panel mode
/// there instead (see RecordingActionRouter).
class PermissionDeniedDialog {
  const PermissionDeniedDialog._();

  static Future<void> show(
    BuildContext context,
    PermissionKind kind, {
    ScreenRecordingPermissionPurpose screenRecordingPurpose =
        ScreenRecordingPermissionPurpose.screenCapture,
  }) {
    return showDesktopDialog<void>(
      context: context,
      builder: (_) => _PermissionDeniedBody(
        kind: kind,
        screenRecordingPurpose: screenRecordingPurpose,
      ),
    );
  }
}

/// Full-screen presentation. Pushed by the recording bar (which switches to
/// panel mode first) because the bar window is too short for a dialog.
/// Renders the same content as [PermissionDeniedDialog], full-bleed.
class PermissionDeniedScreen extends StatelessWidget {
  const PermissionDeniedScreen({
    super.key,
    required this.kind,
    this.screenRecordingPurpose =
        ScreenRecordingPermissionPurpose.screenCapture,
  });
  final PermissionKind kind;
  final ScreenRecordingPermissionPurpose screenRecordingPurpose;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _PermissionDeniedBody(
          kind: kind,
          screenRecordingPurpose: screenRecordingPurpose,
        ),
      ),
    );
  }
}
