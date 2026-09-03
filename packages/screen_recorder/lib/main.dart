import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Directory, File, Platform;
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
import 'package:slipreel_engine/utils/breadcrumbs.dart';
import 'analytics/analytics_config.dart';
import 'analytics/analytics_events.dart';
import 'analytics/analytics_queue_store.dart';
import 'analytics/analytics_service.dart';
import 'analytics/posthog_sink.dart';
import 'diagnostics/diagnostics_service.dart';
import 'diagnostics/exception_event_builder.dart';
import 'diagnostics/global_error_handlers.dart';
import 'diagnostics/native_crash_scanner.dart';
import 'diagnostics/persistent_crumb_store.dart';
import 'diagnostics/pii_scrubber.dart';
import 'feedback/feedback_service.dart';
import 'debug/debug_probe.dart';
import 'licensing/auth_state_store.dart';
import 'licensing/build_release_date.g.dart';
import 'licensing/deep_link_listener.dart';
import 'licensing/device_fingerprint.dart';
import 'licensing/entitlement.dart';
import 'licensing/export_gate.dart';
import 'licensing/entitlement_public_key.g.dart';
import 'licensing/entitlement_verifier.dart';
import 'licensing/license_store.dart';
import 'licensing/licensing_api.dart';
import 'licensing/licensing_controller.dart';
import 'platform/native_deps.dart';
import 'platform/window_chrome_channel.dart';
import 'onboarding/onboarding_store.dart';
import 'onboarding/tips_controller.dart';
import 'onboarding/tips_store.dart';
import 'state/hotkey_controller.dart';
import 'state/long_recording_watcher.dart';
import 'state/permissions_controller.dart';
import 'state/recording_action_router.dart';
import 'state/global_preferences_controller.dart';
import 'state/global_preferences_store.dart';
import 'state/recording_settings_controller.dart';
import 'state/recording_settings_store.dart';
import 'state/sleep_observer.dart';
import 'state/app_palette_controller.dart';
import 'state/app_palette_store.dart';
import 'state/snap_preference_store.dart';
import 'state/snap_preference_controller.dart';
import 'state/wallpaper_favorites_store.dart';
import 'state/wallpaper_favorites_controller.dart';
import 'state/window_mode_controller.dart';
import 'ui/app_alerts/alert_stack_overlay.dart';
import 'ui/app_alerts/app_alerts.dart';
import 'ui/app_alerts/app_alerts_controller.dart';
import 'ui/theme/app_palette.dart';
import 'state/recording_state.dart';
import 'state/recovery_service.dart';
import 'state/session_marker.dart';
import 'ui/bar/recording_bar_screen.dart';
import 'ui/bar/recording_toast.dart';
import 'ui/bar/wake_modal.dart';
import 'ui/screens/onboarding/onboarding_screen.dart';
import 'ui/screens/playback_screen.dart';
import 'ui/widgets/recovery_modal.dart';
import 'ui/widgets/zoom/playback_canvas.dart';
import 'update/updater_backend.dart';
import 'update/updater_service.dart';
import 'package:slipreel_engine/models/recording_history.dart';

/// Navigator key used by the recording surface widgets (WakeModal,
/// RecordingToast) to obtain a valid [BuildContext] outside the normal
/// widget tree.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Application-wide [RecordingHistoryStore] provider.
/// Exposed here so tests and other entry points can override it via
/// [ProviderScope.overrides].
final recordingHistoryStoreProvider = Provider<RecordingHistoryStore>(
  (ref) => RecordingHistoryStore(),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize logging system
  AppLogger.initialize(level: Level.debug);

  // Prefer the CLI binaries bundled in Contents/Helpers (release builds);
  // dev builds without them keep resolving from Homebrew/PATH.
  NativeDeps.wireBundledBinaries();

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

  final sessionMarkerStore = SessionMarkerStore(
    path: p.join(
      (await getApplicationSupportDirectory()).path,
      'current_sessions.json',
    ),
  );
  final recoveryService = RecoveryService(markerStore: sessionMarkerStore);
  final recoveryCandidates = await recoveryService.scan();

  final onboardingStore = OnboardingStore();
  final onboardingDone = await onboardingStore.load();

  final tipsStore = TipsStore();
  final tipsController = TipsController(tipsStore);
  await tipsController.load();

  final recordingSettingsStore = RecordingSettingsStore(
    path: p.join(
      (await getApplicationSupportDirectory()).path,
      'recording_settings.json',
    ),
  );
  final initialRecordingSettings = await recordingSettingsStore.load();

  final globalPreferencesStore = GlobalPreferencesStore(
    path: p.join(
      (await getApplicationSupportDirectory()).path,
      'global_preferences.json',
    ),
  );
  final initialGlobalPreferences = await globalPreferencesStore.load();

  final paletteStore = await AppPaletteStore.resolveDefault();
  final initialPalette = (await paletteStore.load()) ?? PaletteId.midnight;

  final snapPreferenceStore = await SnapPreferenceStore.resolveDefault();
  final snapEnabledInitial = snapPreferenceStore.load();

  final wallpaperFavoritesStore =
      await WallpaperFavoritesStore.resolveDefault();
  final initialFavorites = wallpaperFavoritesStore.load();

  if (kDebugMode || kProfileMode) {
    _registerSlipreelDebugExtensions(tipsController: tipsController);
  }

  // Auto-update (macOS only). Construct once, wire Sparkle's feed + daily
  // background check at startup, and share the same instance with the
  // Settings "Check for updates" tile via the provider override below.
  final updaterService = UpdaterService(SparkleUpdaterBackend());
  if (Platform.isMacOS) {
    unawaited(updaterService.init());
  }

  // Licensing: load the cached entitlement token, verify it offline, and wire
  // the slipreel:// deep-link handoff. Constructed here (like UpdaterService)
  // so the same instance is shared via the provider override below. Storage is
  // a file in the app-support dir (not the Keychain): flutter_secure_storage
  // needs a keychain-access-groups entitlement that forces provisioning-profile
  // signing. A file is fine for the offline-license threat model (spec 12).
  final licensingKv = FileSecureKV(
    p.join((await getApplicationSupportDirectory()).path, 'licensing.json'),
  );
  final licensingStore = SecureLicenseStore(licensingKv);
  final licensingController = LicensingController(
    store: licensingStore,
    verifier: EntitlementVerifier(kEntitlementPublicKey),
    api: LicensingApi(),
    authState: AuthStateStore(licensingKv),
  );
  await licensingController.load();
  final deepLinkListener = DeepLinkListener(licensingController);
  unawaited(deepLinkListener.start());
  if (Platform.isMacOS) {
    // Refresh in the background on launch (best-effort; offline keeps cache).
    unawaited(licensingController.refreshNow());
  }

  // Product analytics (opt-out: on unless the user turned it off in Settings).
  // No-ops entirely unless a project key was baked in via --dart-define. The
  // distinct_id reuses the device fingerprint (already a one-way hash that
  // never exposes the raw hardware id); if the platform can't supply one we
  // fall back to a persisted random id so events still stitch into a funnel.
  final appSupportPath = (await getApplicationSupportDirectory()).path;
  // Resolved once here and shared across analytics, diagnostics, and feedback
  // so all three stitch to the same PostHog person.
  final distinctId = await _resolveAnalyticsDistinctId(appSupportPath);
  final analyticsService = AnalyticsService(
    store: AnalyticsQueueStore(
      path: p.join(appSupportPath, 'analytics_queue.json'),
    ),
    distinctId: distinctId,
    enabled: initialGlobalPreferences.shareAnalytics,
    superProperties: {
      'source': 'app',
      'platform': Platform.operatingSystem,
    },
  );
  await analyticsService.load();
  analyticsService.capture(AnalyticsEvents.appOpened);

  // Diagnostics (crash/exception reporting) + feedback, gated by the user's
  // diagnostics opt-out. Shared meta rides on every event; the PII scrubber and
  // breadcrumb buffer are reused across both services. All best-effort: a
  // failure here never blocks app startup.
  // Best-effort: a PackageInfo failure must not block launch (mirrors the
  // guarded call in settings_screen.dart).
  String appVersion;
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
  } catch (_) {
    appVersion = '0.0.0+0';
  }
  // Per-launch session id, shared by diagnosticsMeta (so handled Dart events
  // carry it) and the persistent crumb store (so a next-launch native-crash
  // scan can correlate a crashed session's crumbs back to it). Same 16-byte-hex
  // Random.secure() mechanism as _resolveAnalyticsDistinctId's fallback id.
  final sessionRnd = Random.secure();
  final sessionId = List<int>.generate(16, (_) => sessionRnd.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final diagnosticsMeta = <String, Object?>{
    'source': 'app',
    'platform': Platform.operatingSystem,
    'app_version': appVersion,
    'session_id': sessionId,
  };
  final scrubber = PiiScrubber.forCurrentUser();

  final diagnosticsService = DiagnosticsService(
    sink: PostHogSink(
      store: AnalyticsQueueStore(
        path: p.join(appSupportPath, 'diagnostics_queue.json'),
      ),
      distinctId: distinctId,
      projectKey: AnalyticsConfig.projectKey,
      host: AnalyticsConfig.hostResolved,
    ),
    builder: ExceptionEventBuilder(scrubber: scrubber, meta: diagnosticsMeta),
    breadcrumbs: Breadcrumbs.instance,
    scrubber: scrubber,
    enabled: initialGlobalPreferences.shareDiagnostics,
  );
  await diagnosticsService.load();

  final feedbackService = FeedbackService(
    sink: PostHogSink(
      store: AnalyticsQueueStore(
        path: p.join(appSupportPath, 'feedback_queue.json'),
      ),
      distinctId: distinctId,
      projectKey: AnalyticsConfig.projectKey,
      host: AnalyticsConfig.hostResolved,
    ),
    breadcrumbs: Breadcrumbs.instance,
    scrubber: scrubber,
    meta: diagnosticsMeta,
  );
  await feedbackService.load();

  // Route Flutter framework + async errors to the diagnostics sink. Installed
  // before runApp so early build/async failures are captured. Async capture is
  // handled by PlatformDispatcher.onError inside this call (the documented
  // replacement for runZonedGuarded since Flutter 3.3), so runApp stays
  // unwrapped to avoid a zone/binding mismatch.
  installGlobalErrorHandlers(onCapture: diagnosticsService.captureException);

  // Persistent crumb trail for the native crash scanner (v1b): mirrors the
  // in-memory breadcrumb ring to disk so a full-app crash (which never runs
  // Dart shutdown code) still leaves a trail for the next launch to attach to
  // the parsed crash report. A surviving session.json at next launch means
  // this session didn't exit cleanly; clearOnCleanExit() is what erases it on
  // every clean-exit path (see shareDiagnostics listener + lifecycle flush
  // below) so "survived" reliably means "crashed".
  // Constructing the store and reading the previous session are wrapped
  // together: a failure here must never leave `crumbStore` unusable for the
  // provider override / lifecycle hooks below, so the fallback on error is a
  // disabled store (never writes) rather than no store at all.
  final crumbStorePath = p.join(appSupportPath, 'diagnostics', 'session.json');
  late final PersistentCrumbStore crumbStore;
  PersistedSession? previousSession;
  try {
    crumbStore = PersistentCrumbStore(
      path: crumbStorePath,
      sessionId: sessionId,
      breadcrumbs: Breadcrumbs.instance,
      scrubber: scrubber,
      enabled: initialGlobalPreferences.shareDiagnostics,
    );
    // Read the previous (possibly crashed) session BEFORE this session writes.
    previousSession = crumbStore.readPrevious();
  } catch (_) {
    crumbStore = PersistentCrumbStore(
      path: crumbStorePath,
      sessionId: sessionId,
      breadcrumbs: Breadcrumbs.instance,
      scrubber: scrubber,
      enabled: false,
    );
  }

  // After first frame: forward any native crash reports from macOS's crash
  // reporter, then start mirroring this session's crumbs. Best-effort; never
  // blocks launch.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    try {
      if (initialGlobalPreferences.shareDiagnostics) {
        NativeCrashScanner(
          reportsDir: Directory(p.join(Platform.environment['HOME'] ?? '',
              'Library', 'Logs', 'DiagnosticReports')),
          watermarkStore: NativeCrashWatermarkStore(
              path: p.join(appSupportPath, 'diagnostics',
                  'native_crash_watermark.json')),
          scrubber: scrubber,
          onCrash: (report) {
            // Attach the crashed session's crumb trail ONLY to a report that
            // plausibly belongs to that session's lifetime. A backlog crash
            // (older than this session's launch, or with unknown timestamps)
            // is forwarded crumb-less, exactly like the subprocess case, so it
            // can't inherit an unrelated session's trail.
            final attach = crumbTrailAppliesTo(previousSession, report);
            diagnosticsService.captureNativeCrash(
              report,
              breadcrumbs:
                  attach ? (previousSession?.breadcrumbs ?? const []) : const [],
              activity: attach ? previousSession?.activity : null,
              sessionId: attach ? previousSession?.sessionId : null,
            );
          },
        ).scan();
      }
      // Start this session's trail (the first write resets session.json for
      // the new session, replacing whatever the scanner above just read).
      crumbStore.start();
      crumbStore.writeIfDirty();
    } catch (_) {}
  });

  runApp(ProviderScope(
    overrides: [
      motionTuningProvider.overrideWith(
        // New sessions default to the cinematic feedforward baked from the
        // tuned Studio Soft feel (#7); a saved tuning still wins if present.
        (ref) => MotionTuningController(
          initial: loadedTuning ?? MotionTuning.cinematic,
        ),
      ),
      motionTuningStoreProvider.overrideWithValue(tuningStore),
      onboardingStoreProvider.overrideWithValue(onboardingStore),
      tipsStoreProvider.overrideWithValue(tipsStore),
      tipsControllerProvider.overrideWith((ref) => tipsController),
      windowChromeProvider.overrideWithValue(MethodChannelWindowChrome()),
      permissionsControllerProvider.overrideWith((ref) => permissionsController),
      recordingSettingsStoreProvider.overrideWithValue(recordingSettingsStore),
      recordingSettingsControllerProvider.overrideWith((ref) =>
          RecordingSettingsController(
              store: recordingSettingsStore,
              initial: initialRecordingSettings)),
      globalPreferencesStoreProvider.overrideWithValue(globalPreferencesStore),
      globalPreferencesControllerProvider.overrideWith((ref) =>
          GlobalPreferencesController(
              store: globalPreferencesStore,
              initial: initialGlobalPreferences)),
      sessionMarkerStoreProvider.overrideWithValue(sessionMarkerStore),
      recoveryServiceProvider.overrideWith((ref) => recoveryService),
      recordingControllerProvider.overrideWith((ref) => RecordingController(
            sessionMarkerStore: sessionMarkerStore,
          )),
      appPaletteControllerProvider.overrideWith(
        (ref) => AppPaletteController(
          store: paletteStore,
          initial: initialPalette,
        ),
      ),
      snapPreferenceProvider.overrideWith(
        (ref) => SnapPreferenceController(
          store: snapPreferenceStore,
          initial: snapEnabledInitial,
        ),
      ),
      wallpaperFavoritesProvider.overrideWith(
        (ref) => WallpaperFavoritesController(
          store: wallpaperFavoritesStore,
          initial: initialFavorites,
        ),
      ),
      updaterServiceProvider.overrideWithValue(updaterService),
      licensingControllerProvider.overrideWith((ref) => licensingController),
      analyticsServiceProvider.overrideWithValue(analyticsService),
      diagnosticsServiceProvider.overrideWithValue(diagnosticsService),
      crumbStoreProvider.overrideWithValue(crumbStore),
      feedbackServiceProvider.overrideWithValue(feedbackService),
    ],
    child: MyApp(
      onboardingDone: onboardingDone,
      recoveryCandidates: recoveryCandidates,
    ),
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

/// distinct_id for analytics: prefer the device fingerprint (a sha256 of the
/// hardware id — anonymous, stable per machine). If the platform can't supply
/// one, persist a random id in a sidecar so events from this install still
/// group together. Falls back to a constant only if even that write fails.
Future<String> _resolveAnalyticsDistinctId(String appSupportPath) async {
  try {
    return await DeviceFingerprint().compute();
  } catch (_) {
    try {
      final file = File(p.join(appSupportPath, 'analytics_id'));
      if (file.existsSync()) {
        final existing = (await file.readAsString()).trim();
        if (existing.isNotEmpty) return existing;
      }
      final rnd = Random.secure();
      final id = List<int>.generate(16, (_) => rnd.nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      await file.create(recursive: true);
      await file.writeAsString(id);
      return id;
    } catch (_) {
      return 'anonymous';
    }
  }
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({
    super.key,
    required this.onboardingDone,
    required this.recoveryCandidates,
  });

  final bool onboardingDone;
  final List<RecoveryCandidate> recoveryCandidates;

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  RecordingActionRouter? _router;
  HotkeyController? _hotkeyController;
  SleepObserver? _sleepObserver;
  LongRecordingWatcher? _longWatcher;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _initRecordingSurfaces());
    _wireAnalyticsObservers();
  }

  /// Centralized instrumentation: watch provider state instead of threading an
  /// analytics dependency through every controller. Covers the opt-out toggle,
  /// recording lifecycle (button + hotkey + sleep-observer all land here), and
  /// entitlement becoming active. Export/paywall/zoom events fire from the
  /// playback screen directly, where the metadata lives.
  void _wireAnalyticsObservers() {
    final analytics = ref.read(analyticsServiceProvider);

    ref.listenManual<bool>(
      globalPreferencesControllerProvider.select((p) => p.shareAnalytics),
      (prev, next) => analytics.setEnabled(next),
    );

    ref.listenManual<bool>(
      globalPreferencesControllerProvider.select((p) => p.shareDiagnostics),
      (prev, next) {
        ref.read(diagnosticsServiceProvider).setEnabled(next);
        // Symmetric: opt-out gates writes + deletes the on-disk trail; opt-in
        // (back on mid-session) resumes periodic persistence.
        ref.read(crumbStoreProvider).setEnabled(next);
      },
    );

    ref.listenManual<RecordingStatus>(
      recordingControllerProvider.select((s) => s.status),
      (prev, next) {
        if (prev == next) return;
        if (next == RecordingStatus.recording &&
            prev != RecordingStatus.paused) {
          analytics.capture(AnalyticsEvents.recordingStarted);
          // Fires synchronously as part of the same state transition that
          // precedes the native ScreenCaptureKit start (VideoEncoder.start),
          // so a crash in that handoff is captured with this activity set.
          ref.read(crumbStoreProvider).setActivity({'op': 'recording'});
          ref.read(crumbStoreProvider).flushNow();
        } else if (next == RecordingStatus.completed) {
          analytics.capture(AnalyticsEvents.recordingCompleted, properties: {
            'duration_s': ref.read(recordingControllerProvider).duration.inSeconds,
          });
          ref.read(crumbStoreProvider).setActivity(null);
        } else if (next == RecordingStatus.error) {
          ref.read(crumbStoreProvider).setActivity(null);
        }
      },
    );

    ref.listenManual<EntitlementState>(
      entitlementProvider,
      (prev, next) {
        final was = prev != null &&
            canExportNow(prev, appReleaseDate: buildReleaseDate);
        final now = canExportNow(next, appReleaseDate: buildReleaseDate);
        if (now && !was) analytics.capture(AnalyticsEvents.entitlementActivated);
      },
    );

    // Attribution: identify by the entitlement's user id (`sub`) so app events
    // join the same PostHog person as the web (which identifies by the same id
    // and supplies the email). fireImmediately covers an entitlement already
    // loaded at startup; identify() no-ops once identified.
    ref.listenManual<EntitlementState>(
      entitlementProvider,
      (prev, next) {
        if (next is EntitlementLoaded && next.claims.sub.isNotEmpty) {
          analytics.identify(next.claims.sub);
          ref.read(diagnosticsServiceProvider).setDistinctId(next.claims.sub);
          ref.read(feedbackServiceProvider).setDistinctId(next.claims.sub);
        }
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _hotkeyController?.dispose();
    _sleepObserver?.dispose();
    _longWatcher?.dispose();
    // Clear the global so a hot-reload-replaced MyApp doesn't keep callers
    // pointing at the now-disposed router + its stale ProviderContainer.
    if (recordingActionRouterRef == _router) {
      recordingActionRouterRef = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _initRecordingSurfaces() {
    final container = ProviderScope.containerOf(context);
    final router = RecordingActionRouter(container);
    _router = router;
    recordingActionRouterRef = router;
    _hotkeyController = HotkeyController(
      platform: ScreenRecorderPlatform.instance,
      router: router,
      rootContextProvider: () => rootNavigatorKey.currentContext,
    );
    _sleepObserver = SleepObserver(
      platform: ScreenRecorderPlatform.instance,
      router: router,
      container: container,
      onWake: _showWakeModal,
    );
    _longWatcher = LongRecordingWatcher(
      container: container,
      onFire: _onThresholdFire,
    );

    if (widget.recoveryCandidates.isNotEmpty) {
      _showRecoveryModal(widget.recoveryCandidates);
    }
  }

  Future<void> _showRecoveryModal(List<RecoveryCandidate> candidates) async {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    final container = ProviderScope.containerOf(context);
    final svc = container.read(recoveryServiceProvider);
    final history = container.read(recordingHistoryStoreProvider);
    await showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => RecoveryModal(
        candidates: candidates,
        onRecover: (c) => svc.recover(c, history),
        onDiscard: (c) => svc.discard(c),
      ),
    );
  }

  void _showWakeModal() {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => WakeModal(
        title: 'Welcome back',
        body: 'Your recording was paused while the Mac slept.',
        primaryLabel: 'Resume',
        secondaryLabel: 'Stop & save',
        autoStopAfter: const Duration(seconds: 10),
        onPrimary: () {
          Navigator.of(ctx).pop();
          _router?.pauseOrResume();
        },
        onSecondary: () {
          Navigator.of(ctx).pop();
          _router?.stop();
        },
      ),
    );
  }

  void _onThresholdFire(ThresholdAction action) {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    switch (action) {
      case ThresholdAction.toast30:
        RecordingToast.show(ctx, "You've been recording for 30 minutes");
      case ThresholdAction.toast60:
        RecordingToast.show(ctx, "You've been recording for 60 minutes");
      case ThresholdAction.modal90:
        showDialog<void>(
          context: ctx,
          barrierDismissible: false,
          builder: (_) => WakeModal(
            title: 'Still recording?',
            body: "You've been recording for 90 minutes.",
            primaryLabel: 'Continue recording',
            secondaryLabel: 'Stop & save',
            autoStopAfter: const Duration(seconds: 30),
            onPrimary: () => Navigator.of(ctx).pop(),
            onSecondary: () {
              Navigator.of(ctx).pop();
              _router?.stop();
            },
          ),
        );
      case ThresholdAction.hardStop:
        _router?.stop();
        RecordingToast.show(ctx, 'Recording capped at 2 hours and saved');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // User may have flipped a permission in System Settings; re-probe.
      ref.read(permissionsControllerProvider.notifier).refreshAll();
      // Restart crumb persistence in case a transient `detached` (engine
      // detach / window close without a real quit) already stopped the timer
      // via clearOnCleanExit(); otherwise crumb capture would stay off for the
      // rest of the run. start() is idempotent (`_timer ??=`) and early-returns
      // when disabled, so this is safe unconditionally.
      ref.read(crumbStoreProvider).start();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Best-effort deliver anything buffered before we lose foreground.
      // NOTE: paused/hidden fire on mere backgrounding (window hidden,
      // minimized, Space switch), not just true termination — so this must
      // only persist the crumb trail, never delete it or stop the timer.
      // Deleting here would silently kill crumb capture for the rest of the
      // session on the very first backgrounding.
      unawaited(ref.read(analyticsServiceProvider).flush());
      unawaited(ref.read(diagnosticsServiceProvider).flush());
      unawaited(ref.read(feedbackServiceProvider).flush());
      ref.read(crumbStoreProvider).flushNow();
    } else if (state == AppLifecycleState.detached) {
      // detached is the reliable "app is really exiting" signal — mark this
      // as a clean exit so the next-launch scanner doesn't mistake it for a
      // crash. (If detached isn't delivered on this platform/build,
      // session.json survives and could attach this session's crumb trail to
      // a SUBSEQUENT helper crash at next launch — mild over-attribution,
      // accepted vs. losing the trail entirely; to be confirmed in live
      // validation.)
      ref.read(crumbStoreProvider).clearOnCleanExit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedPalette = ref.watch(appPaletteControllerProvider);
    final palette = AppPalette.byId(selectedPalette);
    // Re-attach the alerts overlay on every build. attach() is idempotent
    // — it tears down any prior OverlayEntry/timers — so this safely
    // covers cold start AND hot-restart (which re-runs the App's build).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final overlay = rootNavigatorKey.currentState?.overlay;
      if (overlay != null) {
        AppAlerts.attach(
          overlay,
          (_) => AlertStackOverlay(controller: AppAlertsController.instance),
        );
      }
    });

    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'Slipreel',
      theme: ThemeData(
        colorScheme: palette.toColorScheme(),
        extensions: [palette],
        useMaterial3: true,
        // Dialogs and modal sheets default to a surface near the near-black
        // app background with no border, so they blend in. Give them a clearly
        // elevated surface, a visible border, a real shadow, and a stronger
        // scrim so they read as distinct layers. Palette-derived so it holds
        // across all three palettes.
        dialogTheme: DialogThemeData(
          backgroundColor: Color.lerp(palette.surfaceCard, Colors.white, 0.06),
          surfaceTintColor: Colors.transparent,
          elevation: 24,
          shadowColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: palette.dividerStrong, width: 1),
          ),
        ),
        bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: Color.lerp(palette.surfaceCard, Colors.white, 0.06),
          surfaceTintColor: Colors.transparent,
          modalBarrierColor: Colors.black.withValues(alpha: 0.6),
          elevation: 24,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            side: BorderSide(color: palette.dividerStrong, width: 1),
          ),
        ),
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
