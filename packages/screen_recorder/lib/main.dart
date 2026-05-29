import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:screen_recorder_macos/screen_recorder_macos.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:slipreel_engine/effects/scene_motion_blur.dart';
import 'package:slipreel_engine/rendering/cursor_image_cache.dart';
import 'package:slipreel_engine/rendering/cursor_overlay_painter.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';
import 'package:slipreel_engine/state/motion_tuning_store.dart';
import 'package:slipreel_engine/utils/app_logger.dart';
import 'debug/debug_probe.dart';
import 'platform/window_chrome_channel.dart';
import 'onboarding/onboarding_store.dart';
import 'onboarding/tips_controller.dart';
import 'onboarding/tips_store.dart';
import 'state/permissions_controller.dart';
import 'state/window_mode_controller.dart';
import 'ui/bar/recording_bar_screen.dart';
import 'ui/screens/onboarding/onboarding_screen.dart';
import 'ui/screens/playback_screen.dart';
import 'ui/widgets/scene_blur_overlay.dart';
import 'ui/widgets/zoom/playback_canvas.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize logging system
  AppLogger.initialize(level: Level.debug);

  // Register `ext.qa.*` VM-service extensions so the agent-wires MCP
  // server (running as a separate process) can introspect the live
  // widget tree, capture debugPrint output, and synthesise gestures
  // for end-to-end debugging. No-op in release builds.
  if (kDebugMode || kProfileMode) {
    debugProbe.install();
    AppLogger.platform.i(
      'Debug probe installed (ext.slipreel.* registered)',
    );
  }

  // macOS platform registration. `dartPluginClass: ScreenRecorderMacos` in
  // screen_recorder_macos/pubspec.yaml makes Flutter auto-register via
  // GeneratedPluginRegistrant; this explicit call is kept as a harmless
  // belt-and-suspenders (registerWith just re-sets the same instance) until
  // auto-registration is confirmed on a real `flutter build macos` (which is
  // broken in this dev env). Safe to remove once verified.
  ScreenRecorderMacos.registerWith();
  AppLogger.platform.i('macOS platform registered');

  // Pre-load the cursor motion-blur shader so the very first paint
  // uses the shader path instead of falling back to multi-stamp.
  await CursorOverlayPainter.ensureMotionBlurProgramLoaded();
  await SceneMotionBlurShader.ensureLoaded();

  // Pre-load the OS stock cursor bitmaps (pointing hand, I-beam,
  // resize, etc.) so non-arrow states render pixel-identical to
  // macOS instead of falling back to the hand-coded polygon path.
  // Fire-and-forget — the painter has a polygon fallback for the
  // ~50 ms it takes for the bitmaps to land.
  unawaited(CursorImageCache.load());

  // Load the motion-feel tuning from the user prefs dir. Closes the
  // designer iteration loop: edit the sidecar JSON, restart the app,
  // see the new feel. Missing/corrupt → defaults (silent — store
  // logs corruption but doesn't throw).
  final tuningStore = MotionTuningStore(
    path: p.join(
      (await getApplicationSupportDirectory()).path,
      'motion_tuning.json',
    ),
  );
  final loadedTuning = await tuningStore.load();
  if (loadedTuning != null) {
    AppLogger.platform.i('MotionTuning loaded from ${tuningStore.path}');
  }

  final permissionsController =
      PermissionsController(ScreenRecorderPlatform.instance);
  await permissionsController.refreshAll();

  final onboardingStore = OnboardingStore();
  final onboardingDone = await onboardingStore.load();

  final tipsStore = TipsStore();
  final tipsController = TipsController(tipsStore);
  await tipsController.load();

  if (kDebugMode || kProfileMode) {
    _registerSlipreelDebugExtensions(tipsController: tipsController);
  }

  runApp(ProviderScope(
    overrides: [
      motionTuningProvider.overrideWith(
        (ref) => MotionTuningController(
          initial: loadedTuning ?? MotionTuning.defaults,
        ),
      ),
      motionTuningStoreProvider.overrideWithValue(tuningStore),
      onboardingStoreProvider.overrideWithValue(onboardingStore),
      tipsStoreProvider.overrideWithValue(tipsStore),
      tipsControllerProvider.overrideWith((ref) => tipsController),
      windowChromeProvider.overrideWithValue(MethodChannelWindowChrome()),
      permissionsControllerProvider.overrideWith((ref) => permissionsController),
    ],
    child: MyApp(onboardingDone: onboardingDone),
  ));
}

/// Registers project-specific debug toggles on the Dart VM service so
/// an agent (or any VM-service client) can flip them without rebuilding.
/// Pairs with the agent-wires probe — the probe exposes the standard
/// QA tools, this surface is for slipreel-specific instrumentation.
///
/// [tipsController] is the live in-memory instance created in [main]; passing
/// it here lets the reset hook call [TipsController.load] to refresh the
/// in-memory seen-set immediately after clearing the store, so the next
/// [TipAnchor] that checks [shouldShow] sees the cleared state without
/// requiring an app restart.
///
/// Each extension returns `{'enabled': bool}` so callers can probe
/// state without needing a separate getter. Add new toggles here as
/// the debugging surface grows.
void _registerSlipreelDebugExtensions({TipsController? tipsController}) {
  developer.registerExtension(
    'ext.slipreel.setSceneBlurTrace',
    (method, params) async {
      final raw = params['enabled'];
      final enabled = raw == 'true' || raw == '1';
      sceneBlurTraceEnabled = enabled;
      return developer.ServiceExtensionResponse.result(
        '{"enabled": $enabled}',
      );
    },
  );

  // Playback control for the active editor. Lets the agent drive the
  // transport (play / pause / seek) and read position without hunting
  // for the on-screen buttons. `seek` takes `ms`.
  developer.registerExtension('ext.slipreel.play', (method, params) async {
    // Fire-and-forget: the debug VM hook returns the state snapshot
    // immediately; we don't need to block on the play future completing.
    debugPlaybackController?.play().ignore();
    return developer.ServiceExtensionResponse.result(_playbackStateJson());
  });
  developer.registerExtension('ext.slipreel.pause', (method, params) async {
    debugPlaybackController?.pause().ignore();
    return developer.ServiceExtensionResponse.result(_playbackStateJson());
  });
  developer.registerExtension('ext.slipreel.seek', (method, params) async {
    final ms = int.tryParse(params['ms'] ?? '') ?? 0;
    await debugPlaybackController?.seekTo(Duration(milliseconds: ms));
    return developer.ServiceExtensionResponse.result(_playbackStateJson());
  });
  developer.registerExtension('ext.slipreel.playbackState', (m, p) async {
    return developer.ServiceExtensionResponse.result(_playbackStateJson());
  });

  // Per-frame trace of the visible spring camera focal (PlaybackCanvas).
  developer.registerExtension('ext.slipreel.setCameraFocalTrace',
      (method, params) async {
    final raw = params['enabled'];
    final enabled = raw == 'true' || raw == '1';
    cameraFocalTraceEnabled = enabled;
    return developer.ServiceExtensionResponse.result('{"enabled": $enabled}');
  });

  developer.registerExtension(
    'ext.slipreel.resetOnboarding',
    (method, params) async {
      await OnboardingStore().reset();
      final store = TipsStore();
      await store.clearAll();
      // Reload the in-memory TipsController so the seen-set is cleared
      // immediately; TipAnchors that haven't fired yet will see the reset
      // state on their next shouldShow() check without requiring a restart.
      await tipsController?.load();
      return developer.ServiceExtensionResponse.result('{"reset": true}');
    },
  );
}

String _playbackStateJson() {
  final c = debugPlaybackController;
  if (c == null || !c.value.isInitialized) {
    return '{"attached": false}';
  }
  final v = c.value;
  return '{"attached": true, "isPlaying": ${v.isPlaying}, '
      '"positionMs": ${v.position.inMilliseconds}, '
      '"durationMs": ${v.duration.inMilliseconds}}';
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key, required this.onboardingDone});

  final bool onboardingDone;

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // User may have flipped a permission in System Settings; re-probe.
      ref.read(permissionsControllerProvider.notifier).refreshAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Slipreel',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      debugShowCheckedModeBanner: false,
      // Lets agent-wires resolve routes so the agent can call
      // `wait_for_route("RecordingBarScreen")` etc.
      navigatorObservers: [
        if (debugProbe.navigatorObserver() case final observer?) observer,
      ],
      home: widget.onboardingDone
          ? const RecordingBarScreen()
          : const OnboardingScreen(),
    );
  }
}
