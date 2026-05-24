import 'dart:async';
import 'dart:developer' as developer;

import 'package:agent_wires_probe/agent_wires_probe.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:screen_recorder_macos/screen_recorder_macos.dart';
import 'package:slipreel_engine/effects/scene_motion_blur.dart';
import 'package:slipreel_engine/rendering/cursor_image_cache.dart';
import 'package:slipreel_engine/rendering/cursor_overlay_painter.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';
import 'package:slipreel_engine/state/motion_tuning_store.dart';
import 'package:slipreel_engine/utils/app_logger.dart';
import 'ui/screens/playback_screen.dart';
import 'ui/screens/recording_screen.dart';
import 'ui/widgets/scene_blur_overlay.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize logging system
  AppLogger.initialize(level: Level.debug);

  // Register `ext.qa.*` VM-service extensions so the agent-wires MCP
  // server (running as a separate process) can introspect the live
  // widget tree, capture debugPrint output, and synthesise gestures
  // for end-to-end debugging. No-op in release builds.
  if (kDebugMode || kProfileMode) {
    AgentWiresProbe.install();
    _registerSlipreelDebugExtensions();
    AppLogger.platform.i(
      'AgentWiresProbe installed (ext.qa.* + ext.slipreel.* registered)',
    );
  }

  // Explicitly register the macOS platform implementation
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

  runApp(ProviderScope(
    overrides: [
      motionTuningProvider.overrideWith(
        (ref) => MotionTuningController(
          initial: loadedTuning ?? MotionTuning.defaults,
        ),
      ),
      motionTuningStoreProvider.overrideWithValue(tuningStore),
    ],
    child: const MyApp(),
  ));
}

/// Registers project-specific debug toggles on the Dart VM service so
/// an agent (or any VM-service client) can flip them without rebuilding.
/// Pairs with the agent-wires probe — the probe exposes the standard
/// QA tools, this surface is for slipreel-specific instrumentation.
///
/// Each extension returns `{'enabled': bool}` so callers can probe
/// state without needing a separate getter. Add new toggles here as
/// the debugging surface grows.
void _registerSlipreelDebugExtensions() {
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
    debugPlaybackController?.play();
    return developer.ServiceExtensionResponse.result(_playbackStateJson());
  });
  developer.registerExtension('ext.slipreel.pause', (method, params) async {
    debugPlaybackController?.pause();
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

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
      // `wait_for_route("RecordingScreen")` etc.
      navigatorObservers: [
        if (kDebugMode || kProfileMode)
          AgentWiresProbe.routeTracker.createObserver(),
      ],
      home: const RecordingScreen(),
    );
  }
}
