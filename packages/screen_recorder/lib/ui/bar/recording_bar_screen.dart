import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../../state/frame_settings_provider.dart';
import '../../state/microphone_controller.dart';
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

  // Auto-size: the bar window hugs its content, which varies with the mic
  // (and later system-audio) label. We measure the content Row's intrinsic
  // width after each bar frame and ask the native window to match it.
  final GlobalKey _barContentKey = GlobalKey();
  double? _lastBarWidth;
  WindowMode? _lastMode;
  bool _barWidthCallbackPending = false;

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
        await controller.startRecording(
            microphone: ref.read(microphoneControllerProvider));
      case BarSourceMode.area:
        final region = await ScreenRecorderPlatform.instance.selectRegion();
        if (region == null) return;
        controller.selectSource(
          kind: RecordingSource.area,
          id: region.displayId,
          region: region,
        );
        await controller.startRecording(
            microphone: ref.read(microphoneControllerProvider));
      case BarSourceMode.device:
        break;
    }
  }

  Widget _buildBar() => RecordingBar(
        onPickMode: _pickAndRecord,
        onClose: () => SystemNavigator.pop(),
        onGearTap: _onGearTap,
        onDragStart: () => ref.read(windowChromeProvider).startWindowDrag(),
        microphone: ref.watch(microphoneControllerProvider),
        onMicTap: _onMicTap,
        contentKey: _barContentKey,
      );

  /// Measures the bar content's intrinsic (constraint-independent) width and
  /// asks the native window to hug it. Using the intrinsic width — not the
  /// rendered width — means resizing the window can't feed back into the
  /// measurement, so there's no resize loop. Deduped so we only call native
  /// when the width actually changes.
  void _syncBarWidth() {
    final box = _barContentKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final content = box.getMaxIntrinsicWidth(double.infinity);
    if (!content.isFinite || content <= 0) return;
    // +12 for the bar Container's symmetric horizontal padding (6 + 6).
    final width = (content + 12).ceilToDouble();
    if (_lastBarWidth != null && (_lastBarWidth! - width).abs() < 0.5) return;
    _lastBarWidth = width;
    ref.read(windowChromeProvider).setBarWidth(width);
  }

  Future<void> _onMicTap() async {
    final current = ref.read(microphoneControllerProvider);
    final result =
        await ScreenRecorderPlatform.instance.showMicrophoneMenu(current);
    if (!mounted || result.cancelled) return;
    ref.read(microphoneControllerProvider.notifier).set(result.config);
  }

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

    // On (re)entering bar mode, force a re-measure: native applyMode("bar")
    // resets the window to its default width, so the cached width is stale
    // (otherwise the dedup would suppress the call and leave the bar unhugged).
    if (mode != _lastMode) {
      if (mode == WindowMode.bar) _lastBarWidth = null;
      _lastMode = mode;
    }

    // Hug the bar window to its content after this frame lays out. Only in bar
    // mode — the pill/panel own their own sizes (native also guards on mode).
    // The pending flag coalesces the per-build callbacks into one per frame.
    if (mode == WindowMode.bar && !_barWidthCallbackPending) {
      _barWidthCallbackPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _barWidthCallbackPending = false;
        if (mounted) _syncBarWidth();
      });
    }

    return Scaffold(backgroundColor: Colors.transparent, body: body);
  }
}
