import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/permissions_controller.dart';

const _screenRecordingSettingsUrl =
    'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture';

/// Handle a permission row's "Enable" tap.
///
/// Screen Recording is special: instead of firing macOS's one-time system
/// prompt (which is keyed to the app signature and can't be re-shown to a
/// returning user), open the Privacy > Screen Recording pane and pin the
/// native, non-modal drag-to-add guide beside it. The guide floats next to
/// System Settings and never stacks on top of another dialog, so this is one
/// clean guided flow with no double prompt.
///
/// Every other permission keeps the normal in-app request (its own OS prompt),
/// and its row still exposes "Open System Settings" on a real denial.
Future<void> requestPermissionWithGuide(
  BuildContext context,
  WidgetRef ref,
  PermissionKind kind,
) async {
  if (kind == PermissionKind.screenRecording) {
    final opened = await launchUrl(Uri.parse(_screenRecordingSettingsUrl));
    if (opened) {
      try {
        await ScreenRecorderPlatform.instance
            .showScreenRecordingPermissionGuide();
      } catch (_) {
        // The guide is an enhancement; System Settings still opened.
      }
    }
    return;
  }
  await ref.read(permissionsControllerProvider.notifier).request(kind);
}
