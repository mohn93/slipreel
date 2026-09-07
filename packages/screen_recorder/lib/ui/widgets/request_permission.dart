import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../../state/permission_prompt_log.dart';
import '../../state/permissions_controller.dart';
import 'permission_denied_sheet.dart';

/// Request [kind]. For Screen Recording, if it does not become granted, fall
/// back to the deny sheet — whose "Open System Settings" both opens the Privacy
/// pane and pins the drag-to-add guide beside it.
///
/// Screen Recording's "Enable" button calls `CGRequestScreenCaptureAccess`,
/// which prompts only on a truly first run; a returning user macOS has already
/// recorded a denial for gets no prompt, so without this fallback the button is
/// a dead end with no path to the guide. Mirrors the record-start flow
/// ([RecordingActionRouter.ensureScreenRecording]). Other kinds keep their
/// plain request (their rows already expose "Open System Settings" on a real
/// denial).
Future<void> requestPermissionWithGuide(
  BuildContext context,
  WidgetRef ref,
  PermissionKind kind,
) async {
  final isScreenRec = kind == PermissionKind.screenRecording;
  final log = ref.read(permissionPromptLogProvider);
  // Captured BEFORE requesting: on a true first ask macOS shows its own prompt,
  // so suppress our sheet to avoid stacking two dialogs. Once asked, macOS
  // never prompts again, so the sheet is the only path to the guide.
  final alreadyAsked = isScreenRec && await log.screenRecordingRequested();

  final status =
      await ref.read(permissionsControllerProvider.notifier).request(kind);
  if (isScreenRec) await log.markScreenRecordingRequested();

  if (isScreenRec &&
      status != PermissionStatus.granted &&
      alreadyAsked &&
      context.mounted) {
    await PermissionDeniedSheet.show(context, kind);
  }
}
