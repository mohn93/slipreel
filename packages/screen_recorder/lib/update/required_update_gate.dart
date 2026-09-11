import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/recording_state.dart';
import '../state/window_mode_controller.dart';
import 'required_update.dart';
import 'required_update_dialog.dart';
import 'updater_service.dart';

final _blockingUpdateProvider = Provider<RequiredUpdate?>((ref) {
  final update = ref.watch(requiredUpdateProvider);
  if (update == null) return null;
  final recording = ref.watch(recordingControllerProvider);
  return recording.isRecording || recording.isProcessing ? null : update;
});

/// Lives above the Navigator: recovery, deep links, and recording-completion
/// navigation cannot cover the gate or restore interaction with the app.
class RequiredUpdateGate extends ConsumerStatefulWidget {
  const RequiredUpdateGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<RequiredUpdateGate> createState() => _RequiredUpdateGateState();
}

class _RequiredUpdateGateState extends ConsumerState<RequiredUpdateGate> {
  WindowPanelHold? _panelHold;

  @override
  void initState() {
    super.initState();
    ref.listenManual(_blockingUpdateProvider, (_, next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(_blockingUpdateProvider) != null) {
          _panelHold ??= ref
              .read(windowModeControllerProvider.notifier)
              .holdPanelForModal();
          _panelHold!.ready.ignore();
        } else {
          _panelHold?.release().ignore();
          _panelHold = null;
        }
      });
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _panelHold?.release().ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final update = ref.watch(_blockingUpdateProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: update != null,
          child: AbsorbPointer(absorbing: update != null, child: widget.child),
        ),
        if (update != null) ...[
          const ModalBarrier(dismissible: false, color: Colors.black54),
          FocusScope(
            autofocus: true,
            child: Center(
              child: RequiredUpdateDialog(
                update: update,
                onUpdate: () async {
                  ref.invalidate(requiredUpdateProvider);
                  if (ref.read(requiredUpdateProvider) == null) return;
                  await ref.read(updaterServiceProvider).checkForUpdates();
                },
              ),
            ),
          ),
        ],
      ],
    );
  }
}
