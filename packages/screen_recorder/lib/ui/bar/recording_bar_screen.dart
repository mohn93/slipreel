import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/utils/app_logger.dart';

import '../../onboarding/tips_controller.dart';
import '../../state/camera_controller.dart';
import '../../state/microphone_controller.dart';
import '../../state/recording_action_router.dart';
import '../../state/recording_state.dart';
import '../../state/system_audio_controller.dart';
import '../widgets/countdown_overlay.dart';
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
  // Auto-size: the bar window hugs its content, which varies with the mic
  // (and later system-audio) label. We measure the content Row's intrinsic
  // width after each bar frame and ask the native window to match it.
  static const double _kBarHeight = 68;

  // Extra vertical room added to the bar window while a bar-mode tip is
  // showing, so the compact tip chip can render below the bar without
  // covering it. Chip = 24 top gap + 14 padding + 1-2 lines of body text +
  // 10 + ~38 FilledButton + 14 padding ≈ 130; round up to clear shadows.
  static const double _kBarTipExtraHeight = 150;

  final GlobalKey _barContentKey = GlobalKey();
  ({double w, double h})? _lastBarSize;
  WindowMode? _lastMode;
  bool _barSizeCallbackPending = false;

  // Mic monitor lifecycle: tracks which config is currently being monitored so
  // we can avoid redundant start/stop calls and detect device changes.
  MicrophoneConfig? _monitoredConfig;

  // Cache the level stream once — the getter returns a fresh
  // receiveBroadcastStream() on each call, so we must not call it per-build.
  late final Stream<double> _micLevelStream =
      ScreenRecorderPlatform.instance.micLevelStream;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(windowModeControllerProvider.notifier).showBar();
    });

    // Recording status → pill/panel/bar. Registered once (not per-build) so we
    // don't re-subscribe every frame; the callback guards `mounted` before
    // touching `ref` and fires the window morphs fire-and-forget (unawaited).
    ref.listenManual<RecordingState>(recordingControllerProvider, (prev, next) {
      if (!mounted) return;
      if (next.status == RecordingStatus.recording ||
          next.status == RecordingStatus.processing) {
        unawaited(_window.showPill());
      } else if (prev?.status != RecordingStatus.completed &&
          next.status == RecordingStatus.completed &&
          next.videoPath != null) {
        unawaited(_openPanel(PlaybackScreen(videoPath: next.videoPath!)));
      } else if (next.status == RecordingStatus.error) {
        unawaited(_window.showBar());
      }
    });

    // Keep the mic monitor in sync with window mode + selected mic. Driven by
    // provider listeners (registered once) instead of a per-build post-frame
    // callback, so we don't re-evaluate on every rebuild. `_syncMicMonitor`
    // dedups via `_monitoredConfig`, so the initial call + listener fan-in are
    // idempotent.
    ref.listenManual<WindowMode>(windowModeControllerProvider, (_, mode) {
      if (mounted) _syncMicMonitor(mode, ref.read(microphoneControllerProvider));
    });
    ref.listenManual<MicrophoneConfig?>(microphoneControllerProvider, (_, mic) {
      if (mounted) {
        _syncMicMonitor(ref.read(windowModeControllerProvider), mic);
      }
    });
    // Re-measure the bar when a tip activates/dismisses so its height grows
    // (to host the bubble) and shrinks back.
    ref.listenManual<TipsController>(tipsControllerProvider, (_, __) {
      if (!mounted) return;
      _lastBarSize = null;
      _scheduleBarSync();
    });
    _syncMicMonitor(
      ref.read(windowModeControllerProvider),
      ref.read(microphoneControllerProvider),
    );
  }

  @override
  void dispose() {
    if (_monitoredConfig != null) {
      ScreenRecorderPlatform.instance.stopMicMonitor();
    }
    super.dispose();
  }

  /// Starts/stops the native mic monitor so the level meter only runs while the
  /// bar is showing with a mic selected. Restarts when the device changes.
  void _syncMicMonitor(WindowMode mode, MicrophoneConfig? mic) {
    final shouldMonitor = mode == WindowMode.bar && mic != null;
    if (shouldMonitor) {
      if (_monitoredConfig != mic) {
        _monitoredConfig = mic;
        ScreenRecorderPlatform.instance.startMicMonitor(mic);
      }
    } else if (_monitoredConfig != null) {
      _monitoredConfig = null;
      ScreenRecorderPlatform.instance.stopMicMonitor();
    }
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
        if (!mounted) return;
        await recordingActionRouterRef?.start(context);
      case BarSourceMode.area:
        final region = await ScreenRecorderPlatform.instance.selectRegion();
        if (region == null) return;
        controller.selectSource(
          kind: RecordingSource.area,
          id: region.displayId,
          region: region,
        );
        if (!mounted) return;
        await recordingActionRouterRef?.start(context);
      case BarSourceMode.device:
        final deviceId = await ScreenRecorderPlatform.instance.showDeviceMenu();
        if (deviceId == null || !mounted) return;
        controller.selectSource(kind: RecordingSource.device, id: deviceId);
        if (!mounted) return;
        await recordingActionRouterRef?.start(context);
    }
  }

  Widget _buildBar() {
    return RecordingBar(
      onPickMode: _pickAndRecord,
      onClose: () => SystemNavigator.pop(),
      onGearTap: _onGearTap,
      onDragStart: () => unawaited(
            ref.read(windowChromeProvider).startWindowDrag().catchError(
                  (Object e, StackTrace st) => AppLogger.platform
                      .w('startWindowDrag failed', error: e, stackTrace: st),
                ),
          ),
      microphone: ref.watch(microphoneControllerProvider),
      onMicTap: _onMicTap,
      systemAudio: ref.watch(systemAudioControllerProvider),
      onSystemAudioTap: _onSystemAudioTap,
      camera: ref.watch(cameraControllerProvider),
      onCameraTap: _onCameraTap,
      contentKey: _barContentKey,
      micLevelStream: ref.watch(microphoneControllerProvider) != null
          ? _micLevelStream
          : null,
    );
  }

  /// Schedules a single post-frame `_syncBarSize` call per frame.
  void _scheduleBarSync() {
    if (_barSizeCallbackPending) return;
    _barSizeCallbackPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _barSizeCallbackPending = false;
      if (mounted) _syncBarSize();
    });
  }

  /// Measures the bar content's intrinsic width and pairs it with a bar
  /// height that grows when a bar-mode tip is active so the tip bubble has
  /// room to render below the bar without covering it. Intrinsic width keeps
  /// native resizes from feeding back into the measurement.
  void _syncBarSize() {
    final box = _barContentKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final content = box.getMaxIntrinsicWidth(double.infinity);
    if (!content.isFinite || content <= 0) return;
    final width = (content + 12).ceilToDouble(); // h-padding 6+6
    final hasBarTip =
        ref.read(tipsControllerProvider).activeTip == TipId.barModePicker;
    final height = _kBarHeight + (hasBarTip ? _kBarTipExtraHeight : 0);
    final size = (w: width, h: height);
    if (_lastBarSize != null &&
        (_lastBarSize!.w - size.w).abs() < 0.5 &&
        _lastBarSize!.h == size.h) {
      return;
    }
    _lastBarSize = size;
    unawaited(
      ref.read(windowChromeProvider).setBarSize(size.w, size.h).catchError(
            (Object e, StackTrace st) => AppLogger.platform
                .w('setBarSize failed', error: e, stackTrace: st),
          ),
    );
  }

  Future<void> _onMicTap() async {
    final current = ref.read(microphoneControllerProvider);
    final result =
        await ScreenRecorderPlatform.instance.showMicrophoneMenu(current);
    if (!mounted || result.cancelled) return;
    ref.read(microphoneControllerProvider.notifier).set(result.config);
  }

  Future<void> _onSystemAudioTap() async {
    final current = ref.read(systemAudioControllerProvider);
    final result =
        await ScreenRecorderPlatform.instance.showSystemAudioMenu(current);
    if (!mounted || result.cancelled) return;
    ref.read(systemAudioControllerProvider.notifier).set(result.config);
  }

  Future<void> _onCameraTap() async {
    final current = ref.read(cameraControllerProvider);
    final result =
        await ScreenRecorderPlatform.instance.showCameraMenu(current);
    if (!mounted || result.cancelled) return;
    ref.read(cameraControllerProvider.notifier).set(result.config);
  }

  Future<void> _onGearTap() async {
    final action = await ref.read(windowChromeProvider).showGearMenu();
    if (!mounted || action == null) return;
    switch (action) {
      case 'recents':
        await _openPanel(const RecentsScreen());
      case 'settings':
        await _openPanel(const SettingsScreen());
      case 'quit':
        await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(windowModeControllerProvider);

    final Widget body;
    switch (mode) {
      case WindowMode.pill:
        final state = ref.watch(recordingControllerProvider);
        body = RecordingPill(
          status: state.status,
          elapsed: state.duration,
          onStop: ref.read(recordingControllerProvider.notifier).stopRecording,
          onPauseOrResume: () => recordingActionRouterRef?.pauseOrResume(),
        );
      case WindowMode.bar:
      case WindowMode.panel:
        body = _buildBar();
    }

    // On (re)entering bar mode, force a re-measure: native applyMode("bar")
    // resets the window to its default size, so the cached size is stale
    // (otherwise the dedup would suppress the call and leave the bar unhugged).
    if (mode != _lastMode) {
      if (mode == WindowMode.bar) _lastBarSize = null;
      _lastMode = mode;
    }

    // Hug the bar window to its content after this frame lays out. Only in bar
    // mode — the pill/panel own their own sizes (native also guards on mode).
    // The pending flag coalesces the per-build callbacks into one per frame.
    if (mode == WindowMode.bar) _scheduleBarSync();

    // In bar mode the window may be taller than the bar itself (to host a
    // tip bubble below it). Pin the bar to the top at its natural height so
    // the extra space below is transparent — the bar's solid colour stops at
    // _kBarHeight and the tip overlay renders against the desktop.
    final Widget pinnedBody = mode == WindowMode.bar
        ? Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: _kBarHeight,
              width: double.infinity,
              child: body,
            ),
          )
        : body;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(children: [pinnedBody, const CountdownOverlay()]),
    );
  }
}
