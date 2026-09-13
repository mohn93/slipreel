import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../distribution/distribution_channel.dart';
import '../state/recording_state.dart';
import '../state/window_mode_controller.dart';
import 'store_update_controller.dart';

class StoreUpdateGate extends ConsumerStatefulWidget {
  const StoreUpdateGate({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<StoreUpdateGate> createState() => _StoreUpdateGateState();
}

class _StoreUpdateGateState extends ConsumerState<StoreUpdateGate>
    with WidgetsBindingObserver {
  WindowPanelHold? _hold;
  Timer? _timer;
  bool _opening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!DistributionChannel.isAppStore) return;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(hours: 1), (_) => _refresh());
  }

  void _refresh() =>
      unawaited(ref.read(storeUpdateProvider.notifier).refresh());

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _hold?.release().ignore();
    super.dispose();
  }

  Future<void> _openStore() async {
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      if (!await launchUrl(
        Uri.parse('https://apps.apple.com/app/id6811278947'),
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('Store could not open');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not open the App Store. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!DistributionChannel.isAppStore) return widget.child;
    final policy = ref.watch(storeUpdateProvider);
    final recording = ref.watch(recordingControllerProvider);
    final busy =
        recording.isRecording ||
        recording.isProcessing ||
        ref.watch(activeUpdateExportsProvider) > 0;
    final visible = policy != null && !busy;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (visible) {
        _hold ??= ref
            .read(windowModeControllerProvider.notifier)
            .holdPanelForModal();
        _hold!.ready.ignore();
      } else {
        _hold?.release().ignore();
        _hold = null;
      }
    });
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: visible,
          child: AbsorbPointer(absorbing: visible, child: widget.child),
        ),
        if (visible) ...[
          const ModalBarrier(dismissible: false, color: Colors.black54),
          FocusScope(
            autofocus: true,
            child: Center(
              child: AlertDialog(
                icon: const Icon(Icons.system_update_alt_rounded, size: 32),
                title: Text(
                  policy.required
                      ? 'Update Slipreel to continue'
                      : 'A new Slipreel is ready',
                ),
                content: SizedBox(
                  width: 340,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Slipreel ${policy.version} is available on the App Store.',
                      ),
                      const SizedBox(height: 12),
                      Text(
                        policy.required
                            ? 'This version is no longer supported. Your recordings and projects are saved on this Mac.'
                            : 'Update when you’re ready. Your recordings and projects stay right where they are.',
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  if (!policy.required)
                    TextButton(
                      onPressed: () =>
                          ref.read(storeUpdateProvider.notifier).dismiss(),
                      child: const Text('Later'),
                    ),
                  FilledButton(
                    onPressed: _opening ? null : _openStore,
                    style: FilledButton.styleFrom(
                      foregroundColor: Colors.white,
                    ),
                    child: Text(_opening ? 'Opening…' : 'Open App Store'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
