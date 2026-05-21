import 'dart:async';

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
import 'ui/screens/recording_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize logging system
  AppLogger.initialize(level: Level.debug);

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
      home: const RecordingScreen(),
    );
  }
}
