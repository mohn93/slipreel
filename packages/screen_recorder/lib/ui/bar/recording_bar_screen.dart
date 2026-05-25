import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../../state/frame_settings_provider.dart';
import '../../state/recording_state.dart';
import '../../state/window_mode.dart';
import '../../state/window_mode_controller.dart';
import '../screens/playback_screen.dart';
import '../screens/recents_screen.dart';
import '../screens/settings_screen.dart';
import 'recording_bar.dart';
import 'recording_pill.dart';

/// Root of the app. Hosts the bar/pill and routes Recents/Settings/editor as
/// panels by morphing the window. Single window, three shapes.
class RecordingBarScreen extends ConsumerStatefulWidget {
  const RecordingBarScreen({super.key});

  @override
  ConsumerState<RecordingBarScreen> createState() => _RecordingBarScreenState();
}

class _RecordingBarScreenState extends ConsumerState<RecordingBarScreen> {
  // `FrameSettingsProvider` is a plain ChangeNotifier (not exposed through a
  // Riverpod provider). The Settings panel edits frame appearance through it;
  // we own one instance for the screen's lifetime and pass it down.
  final FrameSettingsProvider _frameSettings = FrameSettingsProvider();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(windowModeControllerProvider.notifier).showBar();
    });
  }

  @override
  void dispose() {
    _frameSettings.dispose();
    super.dispose();
  }

  WindowModeController get _window =>
      ref.read(windowModeControllerProvider.notifier);

  Future<void> _openPanel(Widget child) async {
    await _window.showPanel();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => child));
    if (!mounted) return;
    await _window.showBar();
  }

  Future<void> _pickAndRecord(BarSourceMode mode) async {
    final controller = ref.read(recordingControllerProvider.notifier);
    switch (mode) {
      case BarSourceMode.display:
      case BarSourceMode.window:
        final kind = mode == BarSourceMode.window
            ? RecordingSource.window
            : RecordingSource.screen;
        final picked = await ScreenRecorderPlatform.instance.pickSource(kind);
        if (picked == null) return;
        controller.selectSource(kind: picked.kind, id: picked.id);
        await controller.startRecording();
      case BarSourceMode.area:
        final region = await ScreenRecorderPlatform.instance.selectRegion();
        if (region == null) return;
        controller.selectSource(
          kind: RecordingSource.area,
          id: region.displayId,
          region: region,
        );
        await controller.startRecording();
      case BarSourceMode.device:
        break;
    }
  }

  Widget _buildBar() => RecordingBar(
        onPickMode: _pickAndRecord,
        onClose: () => SystemNavigator.pop(),
        onGearTap: _onGearTap,
      );

  Future<void> _onGearTap() async {
    final action = await ref.read(windowChromeProvider).showGearMenu();
    if (!mounted || action == null) return;
    switch (action) {
      case 'recents':
        await _openPanel(const RecentsScreen());
      case 'settings':
        await _openPanel(SettingsScreen(settingsProvider: _frameSettings));
      case 'quit':
        await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(windowModeControllerProvider);

    ref.listen<RecordingState>(recordingControllerProvider, (prev, next) {
      if (next.status == RecordingStatus.recording ||
          next.status == RecordingStatus.processing) {
        _window.showPill();
      } else if (prev?.status != RecordingStatus.completed &&
          next.status == RecordingStatus.completed &&
          next.videoPath != null) {
        _openPanel(PlaybackScreen(videoPath: next.videoPath!));
      } else if (next.status == RecordingStatus.error) {
        _window.showBar();
      }
    });

    final Widget body;
    switch (mode) {
      case WindowMode.pill:
        final state = ref.watch(recordingControllerProvider);
        body = RecordingPill(
          elapsed: state.duration,
          onStop: ref.read(recordingControllerProvider.notifier).stopRecording,
        );
      case WindowMode.bar:
      case WindowMode.panel:
        body = _buildBar();
    }

    return Scaffold(backgroundColor: Colors.transparent, body: body);
  }
}
