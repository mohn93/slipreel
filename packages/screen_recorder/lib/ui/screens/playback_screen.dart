import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_history_controller.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';
import 'package:video_player/video_player.dart';
import 'package:slipreel_engine/effects/accumulation_cursor_painter.dart'
    show CursorBlurMode, kCursorBlurBaseExposureMs;
import 'package:slipreel_engine/effects/motion_blur_tuning.dart';
import 'package:slipreel_engine/effects/scene_motion_blur.dart';
import 'package:slipreel_engine/models/trim_selection.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/models/export_settings.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/services/destination_handlers.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/state/editor_project_store.dart';
import 'package:slipreel_engine/state/export_settings_store.dart';
import 'package:slipreel_engine/state/export_telemetry_store.dart';
import 'package:slipreel_engine/export/export_estimator.dart';
import 'package:slipreel_engine/models/compression_bitrate.dart';
import 'package:screen_recorder/ui/widgets/cta_spinner.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_panel.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/zoom_context_inspector.dart'
    show ZoomPlacementGeometry;
import 'package:screen_recorder/ui/widgets/inspector/timeline_selection.dart';
import 'package:screen_recorder/ui/widgets/transport/transport_buttons.dart';
import 'package:screen_recorder/ui/widgets/zoom/playback_canvas.dart';
import 'package:screen_recorder/state/zoom_preview_override.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/aspect_ratio_picker.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/canvas_toolbar.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/timeline_scale_slider.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_debug_painter.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/export_dialog.dart';
import 'package:screen_recorder/ui/screens/zoom_shortcuts.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';
import 'package:slipreel_engine/export/gif_export_pipeline.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/export/audio_mix_args.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:screen_recorder/state/waveform_provider.dart';
import 'package:slipreel_engine/state/audio_mix.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/editor/camera_placement_resolver.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/rendering/device_frame_matcher.dart';
import 'package:screen_recorder/ui/widgets/zoom/composed_canvas.dart';
import 'package:slipreel_engine/editor/camera_seed.dart';
import 'package:slipreel_engine/models/camera_sidecar_meta.dart';
import 'package:screen_recorder/state/camera_playback_sync.dart';
import 'package:screen_recorder/state/display_latency_probe.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:slipreel_engine/models/keystroke_group.dart';
import 'package:slipreel_engine/models/keystroke_recording.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/utils/app_logger.dart';
import '../../state/recording_audio_streams_provider.dart';
import '../../onboarding/tip_anchor.dart';
import '../../onboarding/tips_controller.dart';
import '../theme/app_palette_context.dart';
import 'playback/hover_scrub_controller.dart';
import 'playback/trim_controller.dart';
import 'playback/export_controller.dart';
import 'package:screen_recorder/ui/screens/playback/cut_decision.dart';
import 'package:screen_recorder/ui/screens/playback/slice_nav_decision.dart';
import 'package:screen_recorder/state/snap_preference_controller.dart';
import '../../state/global_preferences_controller.dart';
import 'package:slipreel_engine/timeline/slice_navigation.dart'
    show NavDirection;
import 'package:screen_recorder/analytics/analytics_events.dart';
import 'package:screen_recorder/analytics/analytics_service.dart';
import 'package:screen_recorder/diagnostics/diagnostics_service.dart';
import 'package:screen_recorder/diagnostics/persistent_crumb_store.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';
import 'package:screen_recorder/licensing/build_release_date.g.dart';
import 'package:screen_recorder/licensing/export_gate.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/ui/paywall/paywall_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:screen_recorder/ui/widgets/springy_icon_button.dart';
import 'package:screen_recorder/ui/widgets/command_palette/command_palette.dart';

/// Debug hook: the active [PlaybackScreen] publishes its video
/// controller here (in debug/profile builds) so VM-service extensions
/// (`ext.slipreel.*`, registered in main.dart) can drive playback —
/// play / pause / seek / read state — during agent-driven debugging
/// without needing to find and tap the transport buttons. Null when no
/// editor is open.
VideoPlayerController? debugPlaybackController;

/// Every sidecar file Slipreel writes alongside `<videoPath>`. Deleting a
/// recording must unlink all of these or they orphan on disk — notably the
/// `.camera.mov`, which can be hundreds of MB. The video file itself is
/// deleted separately (it's the parent, not a sidecar). Kept as a pure
/// top-level helper so the delete coverage is unit-testable.
List<String> recordingSidecarPaths(String videoPath) => <String>[
  '$videoPath.meta.json',
  '$videoPath.cursor.json',
  '$videoPath.editor.json',
  '$videoPath.editor.json.tmp',
  CameraSidecarMeta.moviePathForVideo(videoPath),
  '$videoPath.camera.json',
  '$videoPath.keystrokes.json',
  '$videoPath.thumb.png',
];

// TODO(slice-editor T10): replace with per-slice reads once the editor
// follows the active clip. Bridges the removed `state.audioMix` getter to
// the synthesized first clip so audio-export call sites compile.
AudioMix _bridgeAudioMix(EditorProjectState state) {
  final clips = state.timeline.clips;
  if (clips.isEmpty) return const AudioMix();
  final c = clips.first;
  return AudioMix(
    micGainPercent: c.micGainPercent,
    micMuted: c.micMuted,
    systemGainPercent: c.systemGainPercent,
    systemMuted: c.systemMuted,
  );
}

/// Pure helper: the effective preview playback rate sent to the video
/// controller is `clipSpeed × previewSpeed`. Exposed at top level so
/// unit tests can verify the math without spinning up the full screen.
@visibleForTesting
double effectivePreviewRate(double clipSpeed, double previewSpeed) =>
    clipSpeed * previewSpeed;

/// Pure helper: returns true when the play-state listener should
/// re-apply the effective rate. The trigger is the false→true edge
/// (resume), because video_player on macOS resets `rate` to 1.0 on
/// every `play()` call. Same-state ticks and pause edges return false.
@visibleForTesting
bool shouldReapplyOnResume({required bool prev, required bool next}) =>
    next && !prev;

/// Pure helper extracted from _PlaybackScreenState's Cmd+K handler so
/// the keybind logic can be unit-tested without a video controller.
/// Returns true on successful split, false otherwise.
@visibleForTesting
bool handleCutKeybind({
  required EditorProjectController controller,
  required Duration currentEditedTime,
  required List<ClipSlice> clips,
}) => controller.splitAtPlayhead(currentEditedTime, clips);

/// Computes the new selected-slice index after [removed] is dropped
/// from clips. Pure for unit testing.
///   - selected == removed → null (the selected slice is gone)
///   - selected > removed → selected - 1 (everything right shifts left)
///   - selected < removed → unchanged
///   - selected == null → null
@visibleForTesting
int? decrementSelectionOnRemoval({
  required int? selected,
  required int removed,
}) {
  if (selected == null) return null;
  if (selected == removed) return null;
  if (selected > removed) return selected - 1;
  return selected;
}

/// Pure helper: returns the index of the slice whose `[trimStart,
/// trimEnd)` range contains [sourcePosition]. Returns -1 when [clips]
/// is empty, or when the position falls outside every slice (e.g. in
/// a gap between slices or past the final trimEnd — a transient state
/// during a seek or after walking off the end).
@visibleForTesting
int activeSliceIndex(List<ClipSlice> clips, Duration sourcePosition) {
  for (var i = 0; i < clips.length; i++) {
    final s = clips[i];
    if (sourcePosition >= s.trimStart && sourcePosition < s.trimEnd) {
      return i;
    }
  }
  return -1;
}

/// Pure helper: returns the [ClipSlice.playbackSpeed] of the slice
/// containing [sourcePosition]. Falls back to 1.0 on empty input, and
/// to the nearest slice's speed (via [clipSliceAt]) when the position
/// sits outside every trimmed range — so resume-at-end and seek-to-zero
/// produce a sensible rate.
@visibleForTesting
double effectiveClipSpeedAt(List<ClipSlice> clips, Duration sourcePosition) {
  if (clips.isEmpty) return 1.0;
  final idx = activeSliceIndex(clips, sourcePosition);
  if (idx != -1) return clips[idx].playbackSpeed;
  return clipSliceAt(clips, sourcePosition).playbackSpeed;
}

/// Returns the source-time position the video controller should seek
/// to when its position-tick reaches [sourcePosition]; null when the
/// current position is already inside a slice's playable trim range.
///
/// When the helper returns the final slice's trimEnd, the caller
/// should ALSO pause the controller — we've walked off the end of
/// the edited timeline.
@visibleForTesting
Duration? shouldSeekOnTick(List<ClipSlice> clips, Duration sourcePosition) {
  if (clips.isEmpty) return null;
  // Already inside a slice's trim range? No seek needed.
  for (final c in clips) {
    if (sourcePosition >= c.trimStart && sourcePosition < c.trimEnd) {
      return null;
    }
  }
  final next = nextPlayPosition(clips, sourcePosition);
  if (next != null) return next;
  return clips.last.trimEnd;
}

/// Source-time position to seek to when the user scrubs to
/// [editedTime] on the timeline. Thin wrapper over editedToSource so
/// the playback-screen call site documents intent.
@visibleForTesting
Duration seekFromEditedTime(List<ClipSlice> clips, Duration editedTime) =>
    editedToSource(clips, editedTime);

/// Preview audio volume for a slice playing at [clipSpeed]: silenced above the
/// auto-mute threshold (matching the export filter graph), full otherwise.
@visibleForTesting
double previewVolumeForSpeed(double clipSpeed) =>
    clipSpeed > kSpeedAudioMuteThreshold ? 0.0 : 1.0;

class PlaybackScreen extends ConsumerStatefulWidget {
  final String videoPath;

  const PlaybackScreen({super.key, required this.videoPath});

  @override
  ConsumerState<PlaybackScreen> createState() => _PlaybackScreenState();
}

class _PlaybackScreenState extends ConsumerState<PlaybackScreen>
    with TickerProviderStateMixin {
  late VideoPlayerController _controller;
  SmoothPlayheadController? _smoothPlayhead;
  DisplayLatencyProbe? _latencyProbe;
  // Single source of truth for the EDITED-time playhead position fed
  // into [EditorTimeline]. Updated by listeners on [_smoothPlayhead]
  // (per vsync while playing), [_controller] (per ~250 ms tick while
  // paused / on seeks), and from each hover-state handler. The timeline
  // subscribes via `ValueListenableBuilder` so per-vsync ticks land on
  // just the playhead subtree instead of rebuilding the whole tree.
  final ValueNotifier<Duration> _playheadEditedPos = ValueNotifier<Duration>(
    Duration.zero,
  );
  bool _isInitialized = false;
  String? _error;
  // Path of the last successfully exported file — used to wire the
  // reveal-in-Finder button in the ExportDialog destination row.
  String? _lastExportPath;

  // True from the moment the user taps Export until the pipeline
  // completes (or aborts). Drives the in-button spinner so the CTA
  // visibly reflects work-in-progress even between the modal phases
  // (settings dialog → progress dialog) when the bare screen flashes
  // for a frame.
  bool _isExporting = false;
  // Owns the trim selection and soft-enforces it during playback.
  // Wired in [_initializeVideo] once the controller is initialised.
  // B-era whole-clip trim — per-slice trim handles in the multi-slice
  // ClipLane (Task 9) now drive the engine via setSliceTrim*, but this
  // controller still enforces playback-boundary behaviour until those
  // paths converge.
  late final TrimController _trim;
  // State-shaped undo/redo for everything the editor notifier owns
  // (cursor visuals, animation configs, motion blur, zoom regions,
  // etc.). Wired in [_initializeVideo] after the project state loads
  // so the initial floor matches the on-disk snapshot. Trim selection
  // is not yet covered — it'll join once trim moves into
  // [EditorProjectState] alongside the timeline container (P2-10).
  EditorHistoryController? _history;
  int? _selectedZoomIndex;
  final _zoomPreviewOverride = ZoomPreviewOverride();
  // Live camera drag/resize preview: the in-flight placement is pushed here per
  // pointer-move (cheap — only the canvas rebuilds) and committed to project
  // state once on drag end, so dragging the bubble doesn't rebuild the whole
  // editor on every frame.
  final ValueNotifier<({int index, CameraPlacement placement})?>
  _cameraDragOverride = ValueNotifier(null);
  // Which slice (if any) the user has tapped in the multi-slice clip
  // lane. Mutually exclusive with [_selectedZoomIndex]: selecting one
  // clears the other. Drives the inspector's context-mode display.
  int? _selectedSliceIndex;

  // True while the scissors toolbar button is engaged. The timeline
  // mounts a CutOverlay above its clip lane, and any tap on the lane
  // commits a cut at that edited-time x. Esc / a successful cut /
  // re-pressing the button all flip this back to false.
  bool _cutModeActive = false;

  // 120ms accent flash on the playhead pill after a rejected Cmd+K
  // cut. Driven by [_flashPlayhead], cancelled in [dispose].
  bool _playheadFlashOn = false;
  Timer? _flashTimer;

  /// Edited-time of the most recent snap target — drives [SnapFlashOverlay].
  /// Cleared by [_snapFlashTimer] after the fade completes.
  Duration? _snapFlashTarget;
  Timer? _snapFlashTimer;

  // Session-only preview-playback-speed multiplier (1×/2×/4×/8×).
  // Picked from the dropdown next to the timeline-zoom slider in the
  // transport bar. Multiplies on top of the per-clip [playbackSpeed]
  // (which drives export) — the effective preview rate sent to the
  // video player is `clipSpeed × _previewPlaybackSpeed`. Not persisted,
  // not undo/redo-tracked, resets to 1.0 each time a project opens.
  double _previewPlaybackSpeed = 1.0;
  // Last value pushed to [_controller.setPlaybackSpeed]. Used so we
  // can re-apply the product when either input changes.
  double _lastClipSpeedApplied = 1.0;

  // Editor-state values (cursor visuals, animation configs, motion-
  // blur knobs, zoom regions, etc.) all live on
  // [editorProjectControllerProvider] now. The notifier exposes an
  // immutable [EditorProjectState] + per-field mutators; the screen
  // reads via [ref.watch] in build() and mutates via these helpers
  // below.
  EditorProjectState get _project => ref.read(editorProjectControllerProvider);
  EditorProjectController get _projectController =>
      ref.read(editorProjectControllerProvider.notifier);

  RecordingMetadata? _metadata;
  DeviceFrameCatalog? _deviceFrameCatalog;
  CursorRecording _cursorRecording = CursorRecording();
  KeystrokeRecording _keystrokeRecording = KeystrokeRecording();
  // Owns hover-scrub state: the user's intended (anchor) position —
  // the spot we return to when a hover-preview ends — and whether a
  // hover-preview is in progress. The anchor is updated continuously
  // while NOT hover-scrubbing (so it tracks playback and committed
  // seeks) and frozen while hovering (so hover seeks don't overwrite
  // it with previewed positions). The colored playhead and time
  // labels display the frozen anchor while hovering; PlaybackCanvas
  // receives `isHovering` as `isHoverScrubbing` so its stateful
  // smoothers bypass. Wired in [_initializeVideo] once
  // the controller is initialised. setState is owned by this widget:
  // it wraps the controller's mutating methods at the call sites.
  late final HoverScrubController _hover;
  // Dev HUD: when on, draws a marker at the recorded cursor's video-pixel
  // position so we can visually confirm the zoom focal is tracking it.
  bool _showZoomDebug = false;

  // Top-bar "View" menu toggles. _showSidebar gates the right-hand
  // InspectorPanel + its divider; _showTimeline gates the entire
  // transport + editor timeline block below the canvas. Both default
  // to on (the standard editor layout). Local to this screen — the
  // user expects the toggle to persist within a session but reset
  // each time they open a recording.
  bool _showSidebar = true;
  bool _showTimeline = true;
  // Backing store for the HUD's text readout. PlaybackCanvas publishes
  // a fresh snapshot into this each frame; the screen-level
  // `ValueListenableBuilder` reads it and renders the panel OUTSIDE
  // the canvas's zoom Transform (so the text stays put even when the
  // video is zoomed in 2× and the canvas content slides off-screen).
  final ValueNotifier<ZoomDebugSnapshot?> _zoomDebugSnapshot =
      ValueNotifier<ZoomDebugSnapshot?>(null);
  // Persistence for user-saved curves shown in the curve editor's
  // Library row. One instance per playback screen so saves survive
  // animation-tab rebuilds.
  final FileCurveLibrary _curveLibrary = FileCurveLibrary();
  // Per-recording editor settings (zoom regions, animation configs,
  // cursor visuals, etc.) — saved to a `<videoPath>.editor.json`
  // sidecar so the user's edits survive across app sessions.
  late final EditorProjectStore _projectStore = EditorProjectStore(
    videoPath: widget.videoPath,
  );
  Timer? _saveDebounce;

  /// Camera sidecar metadata (`.camera.json`) for this recording, or null
  /// when the recording has no camera. Its presence enables the Camera
  /// inspector tab and the camera lane.
  CameraSidecarMeta? _cameraMeta;

  /// Absolute path of the `.camera.mov` when a camera sidecar exists and the
  /// file is present on disk; null otherwise.
  String? _cameraMoviePath;

  /// Second player for the camera sidecar, slaved to [_controller]. Null
  /// until a camera sidecar is confirmed and initialized.
  VideoPlayerController? _cameraController;

  /// Selected camera region index, or null. Mutually exclusive with
  /// [_selectedZoomIndex] / [_selectedSliceIndex].
  int? _selectedCameraIndex;

  /// Whether this recording has a usable camera sidecar.
  bool get _hasCamera => _cameraMeta != null && _cameraMoviePath != null;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
    HardwareKeyboard.instance.addHandler(_onKey);
    ref.captureAnalytics(AnalyticsEvents.screenViewed,
        properties: {'screen': 'editor'});
  }

  /// Global Cmd+K → split at the current playhead's edited time.
  /// Option+] / Option+[ → navigate to next / previous slice.
  /// Success (Cmd+K): clear slice selection. Failure: flash the playhead pill.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final isCmdK =
        event.logicalKey == LogicalKeyboardKey.keyK &&
        HardwareKeyboard.instance.isMetaPressed;
    if (isCmdK) {
      // Need an initialised controller to read the playhead. Bail
      // quietly so the keypress falls through to system handling.
      if (!_isInitialized) return false;
      final clips = ref.read(editorProjectControllerProvider).timeline.clips;
      final sourcePos = _controller.value.position;
      final editedPos = sourceToEdited(clips, sourcePos);
      final snapEnabled = ref.read(snapPreferenceProvider);
      final overrideSnap = HardwareKeyboard.instance.isAltPressed;
      final zoomEdges = <Duration>[
        for (final r
            in ref
                .read(editorProjectControllerProvider)
                .timeline
                .activeZoomRegions) ...[r.startTime, r.endTime],
      ];
      final decision = decideCut(
        playheadEdited: editedPos,
        clips: clips,
        clickTimesSource: _cursorRecording.eventIndex.clickTimes,
        zoomEdgesSource: zoomEdges,
        snapEnabled: snapEnabled,
        overrideSnap: overrideSnap,
      );
      final cutTime = decision.time;
      final snappedTo = decision.snapTarget;
      final ok = handleCutKeybind(
        controller: ref.read(editorProjectControllerProvider.notifier),
        currentEditedTime: cutTime,
        clips: clips,
      );
      if (ok) {
        setState(() {
          _selectedSliceIndex = null;
          _selectedCameraIndex = null;
        });
        if (snappedTo != null) _flashSnap(snappedTo);
      } else {
        // If snap pushed us into the min-slice guard zone, retry at raw position.
        if (snappedTo != null) {
          final fallback = handleCutKeybind(
            controller: ref.read(editorProjectControllerProvider.notifier),
            currentEditedTime: editedPos,
            clips: clips,
          );
          if (fallback) {
            setState(() {
              _selectedSliceIndex = null;
              _selectedCameraIndex = null;
            });
            return true;
          }
        }
        _flashPlayhead();
      }
      return true;
    }

    final isOptBracket =
        HardwareKeyboard.instance.isAltPressed &&
        (event.logicalKey == LogicalKeyboardKey.bracketRight ||
            event.logicalKey == LogicalKeyboardKey.bracketLeft);
    if (isOptBracket) {
      if (!_isInitialized) return false;
      if (_focusedWidgetIsEditable()) return false;
      final clips = ref.read(editorProjectControllerProvider).timeline.clips;
      final dir = event.logicalKey == LogicalKeyboardKey.bracketRight
          ? NavDirection.next
          : NavDirection.previous;
      final decision = decideSliceNav(
        currentIndex: _selectedSliceIndex,
        clips: clips,
        direction: dir,
      );
      if (decision == null) return true;
      if (decision.isBoundaryNoOp) {
        _flashPlayhead();
        return true;
      }
      setState(() {
        _selectedSliceIndex = decision.nextIndex;
        _selectedZoomIndex = null;
        _selectedCameraIndex = null;
      });
      // `decision.seekTo` is in edited-time; the player works in
      // source-time. Convert before seeking or the playhead lands at
      // a source position that may map to a completely different
      // slice in edited-time.
      _controller.seekTo(editedToSource(clips, decision.seekTo));
      return true;
    }

    return false;
  }

  bool _focusedWidgetIsEditable() {
    final focused = FocusManager.instance.primaryFocus?.context?.widget;
    return focused is EditableText;
  }

  void _flashPlayhead() {
    if (!mounted) return;
    setState(() => _playheadFlashOn = true);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() => _playheadFlashOn = false);
    });
  }

  void _flashSnap(Duration target) {
    if (!mounted) return;
    setState(() => _snapFlashTarget = target);
    _snapFlashTimer?.cancel();
    _snapFlashTimer = Timer(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      setState(() => _snapFlashTarget = null);
    });
  }

  /// Compute the inspector's current timeline-selection input from
  /// the screen's selection state. Slice selection wins if both are
  /// somehow set (only one can be set under normal flow because the
  /// tap handlers clear the other) — exposing the slice context is
  /// the more recoverable state in an undo-replay edge case.
  TimelineSelection? _currentSelection() {
    if (_selectedSliceIndex != null) {
      return SliceSelected(_selectedSliceIndex!);
    }
    if (_selectedCameraIndex != null) {
      return CameraSelected(_selectedCameraIndex!);
    }
    if (_selectedZoomIndex != null) {
      return ZoomSelected(_selectedZoomIndex!);
    }
    return null;
  }

  /// Pushes the current effective preview playback rate
  /// (`clipSpeed × _previewPlaybackSpeed`) onto the video controller.
  /// Called whenever either input changes (the active slice's
  /// [ClipSlice.playbackSpeed] via the clips-list `ref.listen` in
  /// build / the boundary-crossing [_onSpeedTick] listener, or the
  /// preview dropdown via [TimelineScaleSlider]).
  void _applyEffectivePlaybackSpeed(double clipSpeed) {
    if (!_isInitialized) return;
    _lastClipSpeedApplied = clipSpeed;
    final effective = effectivePreviewRate(clipSpeed, _previewPlaybackSpeed);
    // VideoPlayerController.setPlaybackSpeed clamps to a non-zero,
    // non-negative value; guard against degenerate inputs.
    if (effective <= 0) return;
    _controller.setPlaybackSpeed(effective);
    // Match the export: drop preview audio for slices sped past the threshold.
    _controller.setVolume(previewVolumeForSpeed(clipSpeed));
  }

  /// Per-instance shim around the top-level [effectiveClipSpeedAt]
  /// helper: reads the live [clips] from the project controller and
  /// delegates. The pure helper is what tests assert against; this
  /// method just plumbs the live state into it.
  double _effectiveClipSpeedAt(Duration sourcePos) => effectiveClipSpeedAt(
    ref.read(editorProjectControllerProvider).timeline.clips,
    sourcePos,
  );

  // Index of the slice currently under the playhead. -1 means no
  // slice contains the position (transient — happens mid-seek across
  // a removed region). Diffed in [_onSpeedTick] so we re-apply the
  // rate exactly once per boundary crossing, not every frame.
  int _currentSliceIndex = -1;

  /// Per-frame boundary-crossing detector. Drives the active slice's
  /// [ClipSlice.playbackSpeed] onto the player whenever the playhead
  /// crosses into a new slice — during continuous playback, after a
  /// committed seek, or after [_onSkipTick]'s gap jump.
  ///
  /// Registered on [_smoothPlayhead] (not [_controller]) because the
  /// controller only reports position updates every ~250 ms — reacting
  /// to those leaves up to 250 ms of wrong-rate playback inside the
  /// new slice (the user-visible "slip"). The smoothed playhead ticks
  /// every frame (~16 ms) and extrapolates slightly ahead of the
  /// last-reported controller position, so we typically catch the
  /// crossing one frame BEFORE AVPlayer decodes past the seam —
  /// giving the platform-channel `setPlaybackSpeed` round-trip time
  /// to land right at the boundary.
  ///
  /// Without this the controller would keep slice 0's rate forever;
  /// the export pipeline honours per-slice speed (`n_slice_filter_graph`
  /// emits `setpts`/`atempo` per slice) so the preview would silently
  /// lie about the export.
  void _onSpeedTick() {
    if (!_isInitialized) return;
    final clips = ref.read(editorProjectControllerProvider).timeline.clips;
    if (clips.isEmpty) return;
    final pos = _smoothPlayhead?.position ?? _controller.value.position;
    final idx = activeSliceIndex(clips, pos);
    if (idx == -1) return; // mid-seek through a gap — wait for landing
    if (idx != _currentSliceIndex) {
      _currentSliceIndex = idx;
      _applyEffectivePlaybackSpeed(clips[idx].playbackSpeed);
    }
  }

  // Tracks the previous `isPlaying` value so [_onPlayStateTick] can
  // detect false→true transitions. video_player on macOS (AVPlayer)
  // resets the `rate` to 1.0 on every `play()` call, so we must
  // re-apply the multiplied speed each time playback resumes.
  bool _prevIsPlaying = false;
  void _onPlayStateTick() {
    if (!_isInitialized) return;
    final isPlaying = _controller.value.isPlaying;
    if (shouldReapplyOnResume(prev: _prevIsPlaying, next: isPlaying)) {
      // Re-evaluate from the current position, not the cached value:
      // if the user paused inside slice[1] and resumes, the cache
      // holds slice 0's rate and would resume at the wrong speed.
      _applyEffectivePlaybackSpeed(
        _effectiveClipSpeedAt(_controller.value.position),
      );
    }
    _prevIsPlaying = isPlaying;
  }

  Future<void> _initializeVideo() async {
    try {
      _controller = VideoPlayerController.file(File(widget.videoPath));
      await _controller.initialize();
      _metadata = await RecordingMetadata.loadForVideo(widget.videoPath);
      _deviceFrameCatalog = await loadDeviceFrameCatalog();
      try {
        _cursorRecording = await CursorRecording.loadFromFile(
          '${widget.videoPath}.cursor.json',
        );
      } catch (_) {
        _cursorRecording = CursorRecording();
      }
      try {
        _keystrokeRecording = await KeystrokeRecording.loadFromFile(
          '${widget.videoPath}.keystrokes.json',
        );
      } catch (_) {
        _keystrokeRecording = KeystrokeRecording();
      }
      _smoothPlayhead = SmoothPlayheadController(
        videoController: _controller,
        vsync: this,
      );
      // Preview-only cursor/video sync: poll the vendored video_player patch for
      // this player's display latency. `playerId` is video_player's internal id
      // (only a @visibleForTesting getter is public, but it is stable in 2.11.x
      // and the only way to key the side channel).
      // ignore: invalid_use_of_visible_for_testing_member
      _latencyProbe = DisplayLatencyProbe(playerId: _controller.playerId)
        ..start();
      // Per-vsync (while playing) and per-controller-tick (paused/seek)
      // updates of the edited-time playhead notifier. Either listener
      // calling _refreshPlayheadEditedPos is cheap and idempotent — the
      // `!=` guard inside it filters no-op writes.
      _smoothPlayhead!.addListener(_refreshPlayheadEditedPos);
      _controller.addListener(_refreshPlayheadEditedPos);

      // Restore the user's saved edits for this recording, if any.
      // Loaded *before* we mark _isInitialized so the very first
      // build sees the persisted state and the canvas doesn't flash
      // its defaults for a frame.
      final saved = await _projectStore.load(
        videoDuration: _controller.value.duration,
      );

      EditorProjectState restored = saved;
      try {
        final hasNoZooms = saved.zoomRegions.isEmpty;
        final hasClicks = _cursorRecording.positions.any((p) => p.isClicked);
        // Device (iPhone/iPad) recordings carry no clicks, so hasClicks is
        // already false; the explicit guard documents that auto-zoom never
        // runs for them even if a future change seeds synthetic cursor data.
        if (hasNoZooms &&
            hasClicks &&
            _metadata != null &&
            !_metadata!.isDeviceCapture) {
          final detected = const AutoZoomDetector().detect(
            cursor: _cursorRecording,
            videoSize: Size(
              _metadata!.widthPx.toDouble(),
              _metadata!.heightPx.toDouble(),
            ),
            videoDuration: _controller.value.duration,
            look: saved.defaultZoomLook,
          );
          if (detected.isNotEmpty) {
            restored = saved.copyWith(zoomRegions: detected);
            // Make auto-placed regions immediately "user-owned" so a
            // subsequent open skips detection — otherwise a user who
            // deletes a region could see it come back next launch.
            await _projectStore.save(restored);
          }
        }
      } catch (e) {
        AppLogger.ui.w(
          'Auto-zoom detection failed; opening editor with empty zoom lane: $e',
        );
      }
      // Camera sidecar: load meta, confirm the movie exists, and seed the
      // first region from the self-view position if none is saved yet
      // (mirrors auto-zoom seeding — the seeded region is saved so a later
      // delete sticks across opens).
      try {
        final meta = await CameraSidecarMeta.loadForVideo(widget.videoPath);
        if (meta != null && meta.frameCount > 0) {
          final moviePath = CameraSidecarMeta.moviePathForVideo(
            widget.videoPath,
          );
          if (await File(moviePath).exists()) {
            _cameraMeta = meta;
            _cameraMoviePath = moviePath;
            if (restored.cameraRegions.isEmpty) {
              final seed = cameraSeedRegion(
                videoDuration: _controller.value.duration,
                selfViewX: meta.selfViewX,
                selfViewY: meta.selfViewY,
              );
              restored = restored.copyWith(cameraRegions: [seed]);
              await _projectStore.save(restored);
            }
          } else {
            AppLogger.ui.w(
              'Camera sidecar meta present but .camera.mov missing at '
              '$moviePath — opening editor without camera.',
            );
          }
        }
      } catch (e) {
        AppLogger.ui.w(
          'Camera sidecar load failed; editor opens without camera: $e',
        );
      }
      // Auto-select a device frame for device captures with no frame set
      // yet, when a Perfect (exact-resolution) match exists. Persist so a
      // later "off" sticks across opens (mirrors auto-zoom seeding).
      try {
        final catalog = _deviceFrameCatalog;
        if (catalog != null &&
            _metadata != null &&
            _metadata!.isDeviceCapture &&
            restored.windowFrame.deviceFrameId == null) {
          final recording = Size(
            _metadata!.widthPx.toDouble(),
            _metadata!.heightPx.toDouble(),
          );
          final nextFrame = windowFrameWithAutoDeviceFrame(
            current: restored.windowFrame,
            catalog: catalog,
            recording: recording,
          );
          if (nextFrame.deviceFrameId != restored.windowFrame.deviceFrameId) {
            restored = restored.copyWith(windowFrame: nextFrame);
            await _projectStore.save(restored);
          }
        }
      } catch (e) {
        AppLogger.ui.w(
          'Auto device-frame selection failed; opening editor without device frame: $e',
        );
      }
      // Push the loaded state into the Riverpod notifier — single
      // source of truth for everything the inspector edits. The
      // ref.listen wired up in build() will route subsequent changes
      // back into _persistProject().
      _projectController.replace(restored);

      // Owns the trim selection + soft-enforces it during playback.
      // Constructed before _trim.selection is assigned below.
      _trim = TrimController(
        pause: _controller.pause,
        seekTo: _controller.seekTo,
      );

      // The init above awaited several slow loads (controller, metadata,
      // cursor/keystroke, project, camera sidecar). If the screen was popped
      // meanwhile the State is disposed — bail before setState() or wiring
      // listeners onto controllers that dispose() has already torn down.
      if (!mounted) return;
      setState(() {
        _isInitialized = true;
        // Initialize trim selection to full duration
        _trim.selection = TrimSelection(
          start: Duration.zero,
          end: _controller.value.duration,
          videoDuration: _controller.value.duration,
        );
      });
      // Seed the preview-rate cache from the slice the playhead is
      // currently inside (typically slice 0 at position zero, but
      // computing it this way keeps the seed correct if anything
      // ever lands us elsewhere on init).
      _applyEffectivePlaybackSpeed(
        _effectiveClipSpeedAt(_controller.value.position),
      );
      // Re-apply the effective rate every time playback resumes:
      // AVPlayer (video_player on macOS) resets `rate` to 1.0 on
      // every `play()` call, so without this listener the dropdown
      // value would silently drop back to 1× after pause/resume.
      _prevIsPlaying = _controller.value.isPlaying;
      _controller.addListener(_onPlayStateTick);
      // Re-apply per-slice rate at every slice boundary crossing
      // (continuous play AND post-seek), so the player honours each
      // slice's [ClipSlice.playbackSpeed] — matching what the export
      // pipeline produces. Registered on the SMOOTHED playhead (not
      // _controller) so the boundary detection runs per-frame instead
      // of per-controller-tick (~250ms) — see [_onSpeedTick].
      _smoothPlayhead!.addListener(_onSpeedTick);
      // Wire state-shaped undo/redo. Starts AFTER `replace(saved)` so
      // the initial history floor is the on-disk snapshot, not the
      // defaults — Cmd-Z from a fresh-loaded recording does nothing
      // (correctly: there's nothing to undo yet). Listen so the
      // toolbar buttons re-enable when a debounced push lands without
      // a coincident editor-state publish.
      _history = EditorHistoryController(controller: _projectController)
        ..addListener(() {
          if (mounted) setState(() {});
        })
        ..start();
      // Auto-pause when playback reaches the trim end. Wired after
      // _isInitialized + _trim.selection are set so the listener never
      // sees a half-initialized state.
      _controller.addListener(_onTrimTick);
      // Skip removed regions during playback. Wired to BOTH the
      // controller (for paused-state manual seeks landing in a gap)
      // AND the smoothed playhead (for per-frame crossing detection
      // during playback — the controller's native tick is ~250 ms,
      // smoothed is per-vsync at ~16 ms). The [_lastSkipTarget] guard
      // inside [_onSkipTick] keeps duplicate fires idempotent.
      _controller.addListener(_onSkipTick);
      _smoothPlayhead!.addListener(_onSkipTick);
      // Seed the hover anchor from the freshly-initialised controller
      // so hover-end-before-any-other-action restores to a meaningful
      // value rather than Duration.zero (which would jump to start).
      _hover = HoverScrubController(
        // Route editor-driven seeks through the smooth playhead first. It
        // moves synchronously and suppresses stale native position reports
        // while AVPlayer decodes the target frame, so clicking near/behind a
        // moving playhead never looks like an ignored click.
        seekTo: (position) {
          unawaited(_smoothPlayhead!.seekTo(position));
        },
        initialPosition: _controller.value.position,
      );
      _controller.addListener(_onHoverTrack);
      // Auto-play on load; fire-and-forget — the play state is tracked via
      // the controller's value listener, not by awaiting this future.
      unawaited(_controller.play());

      // Bring up the camera player (if any) and slave it to the main one.
      if (_hasCamera) {
        await _initCameraPlayer();
      }

      // Probe the recording's audio streams so the audio tab knows which
      // per-track controls to show. Non-fatal — failure leaves it empty.
      try {
        final probedForAudio = await ffmpegProbe(path: widget.videoPath);
        if (mounted) {
          ref.read(recordingAudioStreamsProvider.notifier).state =
              probedForAudio.audioStreams;
        }
      } catch (_) {
        /* leave empty */
      }
    } catch (e) {
      // A missing/corrupt video hits this path fast — the user may already
      // have navigated away, so guard against setState-after-dispose.
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load video: $e';
      });
    }
  }

  Future<void> _initCameraPlayer() async {
    final path = _cameraMoviePath;
    if (path == null) return;
    try {
      final cam = VideoPlayerController.file(File(path));
      await cam.initialize();
      if (!mounted) {
        await cam.dispose();
        return;
      }
      await cam.setVolume(0); // camera track carries no audio; be safe
      if (!mounted) {
        await cam.dispose();
        return;
      }
      _cameraController = cam;
      // Slave play/pause + position to the main controller.
      _controller.addListener(_syncCameraPlayer);
      _syncCameraPlayer();
      if (mounted) setState(() {});
    } catch (e) {
      AppLogger.ui.w('Camera player init failed; camera hidden in editor: $e');
      _cameraController = null;
    }
  }

  void _syncCameraPlayer() {
    final cam = _cameraController;
    final meta = _cameraMeta;
    if (cam == null || meta == null || !cam.value.isInitialized) return;
    final camDur = cam.value.duration;
    final desired = CameraPlaybackSync.desiredCameraPosition(
      mainPosition: _controller.value.position,
      offsetMicros: meta.offsetMicros,
      cameraDuration: camDur,
    );
    // The camera is "within its own span" only when `desired` isn't pinned to
    // an edge by the clamp. Outside the span (before the camera starts or
    // after it ends) we PARK the camera on the clamped frame instead of
    // playing — calling play() on a completed video_player restarts it from 0,
    // which otherwise produces a tail-flicker loop.
    final atEdge = desired <= Duration.zero || desired >= camDur;
    final shouldPlay = _controller.value.isPlaying && !atEdge;

    // Spec §5: slave the camera's playback RATE to the main player.
    final mainRate = _controller.value.playbackSpeed;
    if (cam.value.playbackSpeed != mainRate) {
      cam.setPlaybackSpeed(mainRate);
    }

    if (shouldPlay && !cam.value.isPlaying) {
      cam.play();
    } else if (!shouldPlay && cam.value.isPlaying) {
      cam.pause();
    }

    // Correct drift toward `desired`. At an edge this seeks ONCE to the
    // clamped frame and then stays (cam.position == desired → no re-seek),
    // so there's no per-tick thrash.
    if (CameraPlaybackSync.shouldSeek(
      current: cam.value.position,
      desired: desired,
    )) {
      cam.seekTo(desired);
    }
  }

  /// Soft-trim playback enforcement. Called every controller tick
  /// (position update / play-state change). Pauses + parks the
  /// playhead at trim.end when playback crosses it. Doesn't stop the
  /// user from manually seeking past trim.end — the dim overlay on
  /// the timeline communicates "you're in trimmed-out territory."
  void _onTrimTick() {
    final v = _controller.value;
    _trim.enforce(isPlaying: v.isPlaying, position: v.position);
  }

  // Tracks the last position we asked the controller to skip to so we
  // don't fire another seek before the previous one has landed. Without
  // this guard a slow seek would let position-ticks keep emitting the
  // stale "still in removed region" position, and we'd queue duplicate
  // seekTo calls every frame.
  Duration? _lastSkipTarget;

  /// Position-tick listener that skips removed regions. When playback
  /// walks off a slice's trimEnd, seeks to the next slice's trimStart;
  /// when it lands inside a removed region (e.g. from a manual seek),
  /// seeks forward to the closest playable position; when it's past the
  /// final trimEnd, parks at the final trimEnd and pauses.
  ///
  /// Reads the SMOOTHED playhead position (when available) rather than
  /// the raw [_controller] position. video_player's native position
  /// tick fires every ~250 ms, which is enough time for playback to
  /// walk a long way into a trimmed source range before we detect the
  /// crossing — the visible playhead freezes at the seam for that
  /// duration because [sourceToEdited] collapses all source positions
  /// inside a trim gap to a single edited point. The smoothed value
  /// extrapolates forward at vsync (~16 ms) from the last reported
  /// position, so we detect the crossing within a single frame and
  /// issue the corrective seek immediately. This listener is wired to
  /// both [_controller] (catches paused-state manual seeks landing in
  /// a gap) and [_smoothPlayhead] (catches per-frame playing-state
  /// crossings); the [_lastSkipTarget] guard keeps duplicate fires
  /// cheap and idempotent.
  void _onSkipTick() {
    if (!_isInitialized) return;
    final v = _controller.value;
    final clips = ref.read(editorProjectControllerProvider).timeline.clips;
    final sourcePos = _smoothPlayhead?.position ?? v.position;
    final target = shouldSeekOnTick(clips, sourcePos);
    if (target == null) {
      _lastSkipTarget = null;
      return;
    }
    // Already issued this exact seek — wait for the controller to land
    // before issuing another. Without the guard we'd hammer seekTo on
    // every frame while the in-flight seek is still pending.
    if (_lastSkipTarget == target) return;
    _lastSkipTarget = target;
    if (clips.isNotEmpty &&
        target == clips.last.trimEnd &&
        sourcePos >= target) {
      _controller.pause();
    }
    _controller.seekTo(target);
    // The native seek takes 50–200 ms to land while the target frame
    // decodes. Without telling the smoothed playhead, its extrapolator
    // would keep walking forward off the in-gap base position during
    // that window, and the displayed playhead — fed through
    // [sourceToEdited], which collapses every gap source position to
    // the seam — would freeze at the boundary until v.position caught
    // up. Snapping the smoothed value to the seek target now makes the
    // UI playhead immediately reflect the post-seek position, and the
    // controller's suppress-backward-drift guard keeps it there until
    // v.position lands.
    _smoothPlayhead?.snapForward(target);
  }

  /// Schedule a debounced save so a slider drag doesn't hammer the
  /// disk on every tick. Wired automatically: a `ref.listen` in
  /// build() calls this on every notifier publish.
  void _persistProject() {
    if (!_isInitialized) return; // Don't overwrite on the load pass.
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      _projectStore.save(_project);
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _flashTimer?.cancel();
    _snapFlashTimer?.cancel();
    _zoomPreviewOverride.dispose();
    _cameraDragOverride.dispose();
    // Flush any pending debounced save before tearing down so the
    // user doesn't lose the last change they made before navigating
    // away. Fire-and-forget — atomic write + the store's mutation
    // queue mean a partially-written file is impossible.
    _saveDebounce?.cancel();
    if (_isInitialized) {
      _projectStore.save(_project);
      _controller.removeListener(_onTrimTick);
      _controller.removeListener(_onSkipTick);
      _controller.removeListener(_onHoverTrack);
      _controller.removeListener(_onPlayStateTick);
      _controller.removeListener(_refreshPlayheadEditedPos);
      _smoothPlayhead?.removeListener(_onSpeedTick);
      _smoothPlayhead?.removeListener(_onSkipTick);
      _smoothPlayhead?.removeListener(_refreshPlayheadEditedPos);
    }
    _playheadEditedPos.dispose();
    _smoothPlayhead?.dispose();
    _latencyProbe?.dispose();
    _controller.removeListener(_syncCameraPlayer);
    _cameraController?.dispose();
    _controller.dispose();
    _history?.dispose();
    _zoomDebugSnapshot.dispose();
    super.dispose();
  }

  void _handleUndo() => _history?.undo();
  void _handleRedo() => _history?.redo();

  /// Splits the source video's filename into ("name", ".ext") so the
  /// top bar can dim the extension. Returns ("", "") if the path has
  /// no recognizable basename.
  (String, String) _projectTitleParts() {
    final p = widget.videoPath;
    if (p.isEmpty) return ('', '');
    final lastSlash = p.lastIndexOf('/');
    final base = lastSlash >= 0 ? p.substring(lastSlash + 1) : p;
    final lastDot = base.lastIndexOf('.');
    if (lastDot <= 0) return (base, '');
    return (base.substring(0, lastDot), base.substring(lastDot));
  }

  // Reserved on the LEFT edge of the title bar so the native macOS
  // Left pad for the leading icon group. The macOS window keeps its
  // own title bar above the AppBar (traffic lights live there, not in
  // our toolbar), so we only need a small flush-left gutter.
  static const double _kTrafficLightInset = 12;
  static const double _kTopBarIconSize = 36;
  static const double _kTopBarGlyphSize = 18;

  /// Drop-down anchored to the eye icon in the top bar. Mirrors the
  /// screenstudio "View" menu — two toggles (sidebar / timeline) and
  /// a placeholder "Enter preview mode" action. Positioned at the
  /// button's bottom-left with a small gap so it visually hangs off
  /// the icon.
  Future<void> _showViewMenu(BuildContext anchorContext) async {
    final box = anchorContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay =
        Overlay.of(anchorContext).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final btnTL = box.localToGlobal(Offset.zero, ancestor: overlay);
    final btnBR = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    const verticalGap = 6.0;
    final position = RelativeRect.fromLTRB(
      btnTL.dx,
      btnBR.dy + verticalGap,
      overlay.size.width - btnBR.dx,
      overlay.size.height - btnBR.dy - verticalGap,
    );

    final palette = anchorContext.palette;
    final textPrimary = palette.textPrimary;
    final textDim = palette.textSecondary;

    Widget row({
      required bool checked,
      required IconData glyph,
      required String label,
      String? shortcut,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: checked
                  ? Icon(Icons.check, size: 14, color: textPrimary)
                  : null,
            ),
            const SizedBox(width: 6),
            Icon(glyph, size: 15, color: textPrimary),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (shortcut != null) ...[
              const SizedBox(width: 32),
              const Spacer(),
              Text(
                shortcut,
                style: TextStyle(
                  color: textDim,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ],
        ),
      );
    }

    final result = await showMenu<_ViewMenuAction>(
      context: anchorContext,
      position: position,
      color: palette.surfaceCard,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: palette.dividerSubtle),
      ),
      items: [
        PopupMenuItem<_ViewMenuAction>(
          value: _ViewMenuAction.sidebar,
          height: 34,
          child: row(
            checked: _showSidebar,
            glyph: LucideIcons.panelRight,
            label: 'Show editor sidebar',
          ),
        ),
        PopupMenuItem<_ViewMenuAction>(
          value: _ViewMenuAction.timeline,
          height: 34,
          child: row(
            checked: _showTimeline,
            glyph: LucideIcons.panelBottom,
            label: 'Show editor timeline',
          ),
        ),
        const PopupMenuDivider(height: 8),
        PopupMenuItem<_ViewMenuAction>(
          value: _ViewMenuAction.preview,
          height: 34,
          child: row(
            checked: false,
            glyph: LucideIcons.monitor,
            label: 'Enter preview mode',
            shortcut: '⇧⌘↩',
          ),
        ),
      ],
    );

    if (!mounted || result == null) return;
    switch (result) {
      case _ViewMenuAction.sidebar:
        setState(() => _showSidebar = !_showSidebar);
        break;
      case _ViewMenuAction.timeline:
        setState(() => _showTimeline = !_showTimeline);
        break;
      case _ViewMenuAction.preview:
        // TODO: wire preview mode (full-screen play, chrome dimmed).
        break;
    }
  }

  /// Opens the command palette (the ⌘ icon in the top bar). Groups
  /// are assembled per-invocation from the live project state so
  /// entries like "Restore default zoom ranges" can stay disabled
  /// when there's nothing to restore from.
  Future<void> _showCommandPalette() async {
    final controller = ref.read(editorProjectControllerProvider.notifier);
    final hasZooms = ref
        .read(editorProjectControllerProvider)
        .zoomRegions
        .isNotEmpty;
    final hasCursorClicks = _cursorRecording.positions.any((p) => p.isClicked);
    final hasMetadata = _metadata != null;

    final groups = <CommandPaletteGroup>[
      CommandPaletteGroup(
        title: 'Zoom',
        entries: [
          CommandPaletteEntry(
            label: 'Disable all zoom ranges',
            icon: LucideIcons.ban,
            // No backing flag for "off-but-kept" zooms yet — surface
            // the row so the chrome reads complete, but mark it
            // disabled until the underlying state lands.
            enabled: false,
            action: () {},
          ),
          CommandPaletteEntry(
            label: 'Remove all zoom ranges',
            icon: LucideIcons.trash2,
            enabled: hasZooms,
            action: () {
              controller.replaceZoomRegions(const []);
              _setSelectedZoomIndex(null);
              AppAlerts.success('All zoom ranges removed');
            },
          ),
          CommandPaletteEntry(
            label: 'Restore default zoom ranges',
            icon: LucideIcons.rotateCw,
            enabled:
                hasCursorClicks &&
                hasMetadata &&
                _metadata?.isDeviceCapture != true,
            action: () {
              final detected = const AutoZoomDetector().detect(
                cursor: _cursorRecording,
                videoSize: Size(
                  _metadata!.widthPx.toDouble(),
                  _metadata!.heightPx.toDouble(),
                ),
                videoDuration: _controller.value.duration,
                look: _projectController.current.defaultZoomLook,
              );
              final vs = _videoSize();
              final paddingBefore =
                  _projectController.current.windowFrame.padding.left;
              controller.replaceZoomRegions(detected, videoSize: vs);
              final paddingAfter =
                  _projectController.current.windowFrame.padding.left;
              _setSelectedZoomIndex(null);
              if (paddingAfter > paddingBefore) {
                AppAlerts.info(
                  '3D zoom needs breathing room — padding set to ${paddingAfter.toStringAsFixed(0)}px',
                );
              }
              AppAlerts.success(
                'Restored ${detected.length} zoom range${detected.length == 1 ? '' : 's'} from cursor activity',
              );
            },
          ),
          CommandPaletteEntry(
            label: 'Remove all layouts',
            icon: LucideIcons.trash2,
            // "Layouts" isn't a first-class concept in the editor yet
            // — leave as a placeholder until we know what should map
            // here (output canvas? per-slice layouts? frame
            // templates?).
            enabled: false,
            action: () {},
          ),
        ],
      ),
      CommandPaletteGroup(
        title: 'Export',
        entries: [
          CommandPaletteEntry(
            label: 'Export…',
            icon: LucideIcons.upload,
            enabled: !_isExporting,
            action: _export,
          ),
        ],
      ),
    ];

    await showCommandPalette(context, groups: groups);
  }

  /// Trash icon in the top bar. Shows a destructive confirmation
  /// dialog; on confirm, deletes the source video and ALL of its
  /// sidecar files (metadata, cursor recording, editor project
  /// state) before popping back to the recording screen.
  ///
  /// Deletion is best-effort: each sidecar's deletion is wrapped so a
  /// missing or already-cleaned file doesn't block the rest. The
  /// canonical video file is reported back to the user — if it fails,
  /// we leave the playback screen open with an error and DON'T pop,
  /// so the user can retry from the same context.
  Future<void> _deleteRecording() async {
    final palette = context.palette;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: palette.dividerStrong),
        ),
        title: Text(
          'Delete this recording?',
          style: TextStyle(color: palette.textPrimary),
        ),
        content: Text(
          'The video file and its editor project (zooms, trims, cursor '
          'data, metadata) will be permanently removed. This can\'t be '
          'undone.',
          style: TextStyle(color: palette.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: palette.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Pause the player so we're not holding the video file open
    // while we try to unlink it (macOS tolerates open-file delete,
    // but the sidecar writes from EditorProjectStore could race
    // against our cleanup).
    try {
      await _controller.pause();
    } catch (_) {}

    final sidecars = recordingSidecarPaths(widget.videoPath);
    for (final path in sidecars) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        // Best-effort: missing-file is fine, anything else we just
        // surface via debug log and continue with the next sidecar.
        debugPrint('Failed to delete sidecar $path: $e');
      }
    }

    String? deleteError;
    try {
      final video = File(widget.videoPath);
      if (await video.exists()) await video.delete();
    } catch (e) {
      deleteError = e.toString();
    }

    if (deleteError != null) {
      if (!mounted) return;
      AppAlerts.error('Couldn\'t delete the recording: $deleteError');
      return;
    }

    // Drop it from Recents history too, otherwise it lingers as a greyed
    // "missing file" card despite the "permanently removed" promise.
    try {
      await RecordingHistoryStore().removeByPath(widget.videoPath);
    } catch (e) {
      debugPrint('Failed to remove recording from history: $e');
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    AppAlerts.success('Recording deleted');
  }

  /// Three-zone top bar modeled after the screenstudio chrome:
  ///   LEFT  — traffic-light spacer · folder (record-another) · trash
  ///   CENTER — recording filename, with .ext rendered dim
  ///   RIGHT  — ⌘ palette · undo · redo · divider · presets · eye ·
  ///            gauge · Export CTA
  ///
  /// Icons whose target action isn't yet wired (cmd, trash, presets,
  /// eye, gauge) are intentionally [SpringyIconButton] with
  /// `isEnabled: false` so the chrome reads complete but every
  /// affordance is honest about being a stub. Undo/redo bind to the
  /// editor history controller's canUndo / canRedo.
  PreferredSizeWidget _buildTopBar(BuildContext context) {
    final palette = context.palette;
    final (titleName, titleExt) = _projectTitleParts();
    final canUndo = _history?.canUndo ?? false;
    final canRedo = _history?.canRedo ?? false;
    final dim = palette.textSecondary;

    Widget icon(
      IconData glyph,
      String tip,
      VoidCallback onTap, {
      bool enabled = true,
    }) => SpringyIconButton(
      icon: glyph,
      tooltip: tip,
      isActive: false,
      isEnabled: enabled,
      onTap: onTap,
      size: _kTopBarIconSize,
      iconSize: _kTopBarGlyphSize,
      // Tooltips drop UNDER each top-bar chip so they don't
      // collide with the (left-popping) side-rail tooltips or
      // with the title row above.
      tooltipPlacement: SpringyTooltipPlacement.bottom,
    );

    return AppBar(
      backgroundColor: palette.surfaceElevated,
      elevation: 0,
      toolbarHeight: 56,
      titleSpacing: 0,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: palette.dividerSubtle),
      ),
      leadingWidth: _kTrafficLightInset + _kTopBarIconSize * 2 + 16,
      leading: Padding(
        padding: EdgeInsets.only(left: _kTrafficLightInset, right: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon(
              LucideIcons.folderOpen,
              'Record another',
              () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 4),
            icon(LucideIcons.trash2, 'Delete recording', _deleteRecording),
          ],
        ),
      ),
      centerTitle: true,
      title: titleName.isEmpty
          ? null
          : RichText(
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                children: [
                  TextSpan(
                    text: titleName,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (titleExt.isNotEmpty)
                    TextSpan(
                      text: titleExt,
                      style: TextStyle(
                        color: dim,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),
      actions: [
        icon(LucideIcons.command, 'Commands', _showCommandPalette),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Container(width: 1, height: 22, color: palette.dividerSubtle),
        ),
        icon(LucideIcons.undo2, 'Undo (Cmd+Z)', _handleUndo, enabled: canUndo),
        icon(
          LucideIcons.redo2,
          'Redo (Cmd+Shift+Z)',
          _handleRedo,
          enabled: canRedo,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Container(width: 1, height: 22, color: palette.dividerSubtle),
        ),
        // Eye → "View" menu. Builder captures its own context so the
        // showMenu anchor math points at the eye's render box, not the
        // top-bar parent.
        Builder(
          builder: (ctx) =>
              icon(LucideIcons.eye, 'View options', () => _showViewMenu(ctx)),
        ),
        const SizedBox(width: 12),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TipAnchor(
            tipId: TipId.editorExport,
            child: ElevatedButton.icon(
              onPressed: _isExporting ? null : _export,
              icon: _isExporting
                  ? const CtaSpinner(size: 16)
                  : const Icon(LucideIcons.upload, size: 16),
              label: Text(
                _isExporting ? 'Exporting…' : 'Export',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: palette.accent,
                foregroundColor: Colors.white,
                // Keep the button looking active (not greyed out) while
                // in the loading state — the spinner already says
                // "busy", the disabled colour would just wash out the
                // CTA.
                disabledBackgroundColor: palette.accent,
                disabledForegroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Recomputes the EDITED-time playhead position and pushes it into
  /// [_playheadEditedPos]. Source position resolution mirrors what the
  /// old AnimatedBuilder body did inline: hover-anchor wins when the
  /// user is scrubbing; otherwise the smoothed playhead, falling back
  /// to the raw controller position.
  void _refreshPlayheadEditedPos() {
    if (!mounted || !_isInitialized) return;
    final clips = ref.read(editorProjectControllerProvider).timeline.clips;
    final sourcePos = _hover.isHovering
        ? _hover.intendedPosition
        : (_smoothPlayhead?.position ?? _controller.value.position);
    final next = clips.isEmpty ? sourcePos : sourceToEdited(clips, sourcePos);
    if (_playheadEditedPos.value != next) {
      _playheadEditedPos.value = next;
    }
  }

  void _setSelectedZoomIndex(int? next) {
    if (next != _selectedZoomIndex) {
      _zoomPreviewOverride.value = null;
    }
    setState(() => _selectedZoomIndex = next);
  }

  void _onPlacementPreview(Rect newRect) {
    final idx = _selectedZoomIndex;
    if (idx == null) return;
    final region = _project.zoomRegions[idx];
    _zoomPreviewOverride.value = region.copyWith(
      rect: newRect,
      // Dragging the placement box expresses manual intent — pin the focal to
      // the rect so the canvas previews the chosen framing (and so device
      // zooms, which can't follow a cursor, actually respond to placement).
      followCursor: false,
      // No video clamp for a manual placement: the picker is the single clamp
      // authority (it keeps the magnify-in-place viewport inside the composed
      // canvas), so the focal may legitimately roam into the padding/bezel.
      // Passing videoBounds: null leaves ZoomRegion._constrainRect untouched.
      videoBounds: null,
    );
  }

  void _onPlacementCommit(Rect newRect) {
    final idx = _selectedZoomIndex;
    if (idx != null) {
      final region = _project.zoomRegions[idx];
      _projectController.updateZoomAt(
        idx,
        region.copyWith(
          rect: newRect,
          // Committing a placement pins the focal to the rect (manual), so the
          // saved zoom frames where the user dropped it — required for device
          // recordings and correct for any manual placement.
          followCursor: false,
          // No video clamp for a manual placement: the picker already
          // constrains the focal so the viewport stays inside the composed
          // canvas, which means the focal center may sit in the padding/bezel
          // (outside [0, videoSize]). Clamping it back to video bounds here
          // would undo that. videoBounds: null skips _constrainRect.
          videoBounds: null,
        ),
        videoSize: _videoSize(),
      );
    }
    _zoomPreviewOverride.value = null;
  }

  Size _videoSize() {
    final m = _metadata;
    if (m == null) return Size.zero;
    return Size(m.widthPx.toDouble(), m.heightPx.toDouble());
  }

  /// Resolves the composed-canvas geometry (wallpaper + padding + bezel +
  /// screen) for the placement picker the SAME way `PlaybackCanvas` renders
  /// it — so the picker box matches the live canvas pixel-for-pixel. Returns
  /// null before the video is measured.
  ///
  /// Mirrors the device-frame resolution used for the live canvas and the
  /// scene-blur framing: `OutputCanvasResolver` for the normal canvas, and
  /// `resolveDeviceFrameLayout` (overriding canvasSize / videoRect) when a
  /// compatible device frame is active. Wallpaper category/index/solidColor
  /// come from the current frame, exactly like `_wallpaperLayer`.
  ZoomPlacementGeometry? _placementGeometry(EditorProjectState project) {
    final videoSize = _videoSize();
    if (videoSize.isEmpty) return null;
    final frame = project.windowFrame;
    // Single source of truth for the composed-canvas geometry, shared with the
    // live render (PlaybackCanvas) and the scene-blur framing.
    final composed = resolveComposedCanvas(
      videoSize: videoSize,
      frame: frame,
      aspect: project.outputAspect,
      catalog: _deviceFrameCatalog,
    );
    final deviceLayout = composed.deviceLayout;
    final deviceAsset = composed.deviceAsset;
    final ImageProvider? bezel = deviceAsset != null
        ? AssetImage(deviceAsset.asset)
        : null;

    return ZoomPlacementGeometry(
      canvasSize: composed.canvasSize,
      videoRect: composed.videoRect,
      // Thread the real null-ness through: the render draws no wallpaper
      // layer when the category is null (the dark editor canvas shows
      // through), so the picker shows a matching neutral backdrop rather
      // than a macOS image. Geometry is wallpaper-independent and unchanged.
      wallpaperCategory: frame.wallpaperCategory,
      wallpaperIndex: frame.wallpaperIndex,
      wallpaperSolidColor: frame.solidColor,
      deviceLayout: deviceLayout,
      bezel: bezel,
    );
  }

  /// Click-to-add zoom from the timeline ghost. Spatial rect defaults
  /// to the full video frame; the cursor-follow pipeline handles
  /// re-centering on the recorded cursor.
  void _addZoomAt(Duration start, Duration end) {
    if (!_isInitialized) return;
    final videoSize = _controller.value.size;
    if (videoSize.isEmpty) return;
    if (end <= start) return;

    final zoomRegion = ZoomRegion(
      rect: Rect.fromLTWH(0, 0, videoSize.width, videoSize.height),
      startTime: start,
      duration: end - start,
      zoomLevel: 2.0,
      videoBounds: videoSize,
      // Device (iPhone/iPad) recordings have no cursor to follow, so new
      // zooms must be manual — otherwise the focal chases nonexistent cursor
      // data and the placement rect (the only control we show) is ignored.
      followCursor: _metadata?.isDeviceCapture != true,
      tilt: _projectController.current.defaultZoomLook.tilt,
      movement: _projectController.current.defaultZoomLook.movement,
    );

    final paddingBefore = _projectController.current.windowFrame.padding.left;
    _projectController.addZoom(zoomRegion, videoSize: videoSize);
    ref.read(analyticsServiceProvider).capture(
      AnalyticsEvents.zoomAdded,
      properties: {'mode': 'manual'},
    );
    final paddingAfter = _projectController.current.windowFrame.padding.left;
    if (paddingAfter > paddingBefore) {
      AppAlerts.info(
        '3D zoom needs breathing room — padding set to ${paddingAfter.toStringAsFixed(0)}px',
      );
    }
    _zoomPreviewOverride.value = null;
    setState(() {
      // Auto-select the new zoom so the inspector opens on it.
      _selectedZoomIndex = _project.zoomRegions.length - 1;
      _selectedSliceIndex = null;
    });
    _controller.seekTo(start);
  }

  /// After a look / tilt / movement edit on zoom [index], move the paused
  /// playhead to a frame where the effect is visible (60% into the settled
  /// hold) unless it is already inside the zoom. Never seeks during playback.
  void _revealZoomEffect(int index) {
    if (!_isInitialized || _controller.value.isPlaying) return;
    final regions = _project.zoomRegions;
    if (index < 0 || index >= regions.length) return;
    final zoom = regions[index];
    final position = _controller.value.position;
    if (position >= zoom.startTime && position <= zoom.endTime) return;

    final ramps = zoom.resolvedRampsUs(
      _project.screenAnimationConfig.rampDurationScale,
    );
    final holdUs = zoom.duration.inMicroseconds - ramps.enterUs - ramps.exitUs;
    final intoUs = holdUs > 0
        ? ramps.enterUs + (holdUs * 0.6).round()
        : zoom.duration.inMicroseconds ~/ 2;
    _controller.seekTo(zoom.startTime + Duration(microseconds: intoUs));
  }

  /// Click-to-add a camera region from the lane ghost. Places it at the
  /// current camera look/default size, centered bottom-right, and selects it.
  void _addCameraAt(Duration start, Duration end) {
    if (!_isInitialized || !_hasCamera) return;
    if (end <= start) return;
    final existing = _project.cameraRegions;
    final tmpl = existing.isNotEmpty ? existing.last : null;
    final region = CameraRegion(
      startTime: start,
      duration: end - start,
      centerX: tmpl?.centerX ?? 0.82,
      centerY: tmpl?.centerY ?? 0.82,
      size: tmpl?.size ?? 0.22,
    );
    _projectController.addCameraRegion(region);
    setState(() {
      _selectedCameraIndex = _project.cameraRegions.length - 1;
      _selectedZoomIndex = null;
      _selectedSliceIndex = null;
    });
    _controller.seekTo(start);
  }

  /// Maps an edited-timeline position from [EditorTimeline] to the underlying
  /// source-media position the playback controller seeks against.
  Duration _editedSeekToSource(Duration editedNext) {
    final clips = ref.read(editorProjectControllerProvider).timeline.clips;
    return clips.isEmpty ? editedNext : seekFromEditedTime(clips, editedNext);
  }

  void _checkZoomMarkerClick(Duration position) {
    // Find zoom region near clicked position (within 0.5 seconds).
    const tolerance = Duration(milliseconds: 500);
    final regions = _project.zoomRegions;
    int? newIndex;
    for (var i = 0; i < regions.length; i++) {
      if ((position - regions[i].startTime).abs() < tolerance) {
        newIndex = i;
        break;
      }
    }
    // Only setState when the selection actually changes — otherwise dragging
    // the playhead causes a setState every tick which rebuilds the whole
    // video panel (gradient backdrop + 80px-blur frame shadow + ClipRRect +
    // Transform), making the seek visibly heavy.
    if (newIndex != _selectedZoomIndex) {
      _setSelectedZoomIndex(newIndex);
    }
  }

  /// Toggles a shortcuts-lane bar on/off. A bar is a coalesced group of one
  /// or more presses of the same shortcut; flipping it adds/removes ALL its
  /// member event timestamps in the project's disabled set, so the on-video
  /// overlay and the export hide or show the whole occurrence. The greyed
  /// bar stays on the timeline either way.
  void _toggleKeystrokeGroup(KeystrokeGroup g) {
    final members = <int>[
      for (final e in _keystrokeRecording.events)
        if (e.label == g.label &&
            e.timestampMicros >= g.firstMicros &&
            e.timestampMicros <= g.lastMicros)
          e.timestampMicros,
    ];
    if (members.isEmpty) return;
    final notifier = ref.read(editorProjectControllerProvider.notifier);
    final settings = ref.read(editorProjectControllerProvider).keystrokeOverlay;
    final next = Set<int>.from(settings.disabledKeys);
    // The group's enabled state is keyed on its first press.
    if (next.contains(g.firstMicros)) {
      next.removeAll(members);
    } else {
      next.addAll(members);
    }
    notifier.setKeystrokeOverlay(settings.copyWith(disabledKeys: next));
  }

  Future<void> _export() async {
    // Re-entrancy guard. The Export button stays mounted (the
    // settings/progress dialogs cover but don't replace the playback
    // screen), so double-tapping during a slow probe would otherwise
    // launch two parallel pipelines.
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      await _exportBody();
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _exportBody() async {
    // Funnel entry: the user initiated an export (before any paywall/dialog).
    ref.captureAnalytics(AnalyticsEvents.exportOpened);
    // ── Phase 1: pre-dialog setup (probe + dialog) ─────────────────────
    // Any exception here (bad codec, missing metadata, probe failure)
    // shows a snackbar rather than dying silently.
    final ExportSettings? settings;
    final RecordingMetadata meta;
    final Duration videoDuration;
    final ExportSettingsStore store;
    final ExportTelemetryStore telemetryStore;
    final Size sourceVideoSize;
    // Composed output canvas (sourceVideoSize + aspect-ratio + padding).
    // Drives both the export-dialog dimensions label and the post-export
    // telemetry's area-based normalization so they agree with what the
    // export pipeline actually writes.
    final Size composedVideoSize;

    try {
      store = await ExportSettingsStore.resolveDefault();
      telemetryStore = await ExportTelemetryStore.resolveDefault();
      final defaults = await store.load();
      final persistedMultiplier = await telemetryStore.loadRealtimeMultiplier();

      if (!mounted) return;

      // Load source metadata — needed for dialog (resolution capping,
      // sub-label) and for the pipeline.
      meta = await RecordingMetadata.loadForVideo(widget.videoPath);
      sourceVideoSize = Size(meta.widthPx.toDouble(), meta.heightPx.toDouble());
      final projectForExport = ref.read(editorProjectControllerProvider);
      composedVideoSize = OutputCanvasResolver.resolve(
        videoSize: sourceVideoSize,
        padding: projectForExport.windowFrame.padding,
        aspect: projectForExport.outputAspect,
      ).canvasSize;

      // Probe the video to get the authoritative duration + audio bitrate.
      final probed = await ffmpegProbe(
        path: widget.videoPath,
        metadataFps: meta.fps,
      );
      videoDuration = probed.durationSec != null
          ? Duration(milliseconds: (probed.durationSec! * 1000).round())
          : Duration.zero;

      if (!mounted) return;

      // Export gate (spec §2/§9). If not entitled, show the paywall instead of
      // the export dialog. The sheet auto-advances (returns true) if the user
      // becomes entitled via the browser flow while it's open.
      final entitlementState = ref.read(entitlementProvider);
      if (!canExportNow(entitlementState, appReleaseDate: buildReleaseDate)) {
        final reason =
            paywallReasonFor(entitlementState, appReleaseDate: buildReleaseDate)!;
        ref.read(analyticsServiceProvider).capture(
          AnalyticsEvents.paywallShown,
          properties: {'reason': reason.name},
        );
        final becameEntitled = await PaywallSheet.show(context, reason: reason);
        if (!becameEntitled || !mounted) return;
        // fall through to the export dialog now that export is unlocked
      }

      settings = await showDialog<ExportSettings>(
        context: context,
        builder: (_) => ExportDialog(
          initialSettings: defaults,
          sourceVideoSize: composedVideoSize,
          videoDuration: videoDuration,
          // TODO(slice-editor T10): build the AudioMix from the active
          // clip once the editor follows per-slice audio settings.
          audioBitrateKbps: buildAudioMixArgs(
            probed.audioStreams,
            _bridgeAudioMix(ref.read(editorProjectControllerProvider)),
          ).bitrateKbps,
          estimator: ExportEstimator(
            lastRealtimeMultiplier: persistedMultiplier ?? 0.7,
          ),
          onRevealLastExport: _lastExportPath == null
              ? null
              : () {
                  // nit: clipboard / shareable-link exports record a temp path
                  // the OS may have reaped. Check before revealing so the
                  // button fails loudly instead of silently no-op'ing.
                  final path = _lastExportPath!;
                  if (!File(path).existsSync()) {
                    AppAlerts.warning('That export is no longer available.');
                    return;
                  }
                  if (Platform.isMacOS) {
                    unawaited(
                      Process.run('open', [
                        '-R',
                        path,
                      ]).catchError((_) => ProcessResult(0, 1, '', '')),
                    );
                  }
                },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppAlerts.error('Couldn\'t prepare export: $e');
      return;
    }

    if (settings == null || !mounted) return;

    // ── GIF >60s gate ──────────────────────────────────────────────────
    if (settings.format == ExportFormat.gif && videoDuration.inSeconds > 60) {
      AppAlerts.warning(
        'GIF export is limited to clips of 60 seconds or less. '
        'Try MP4 instead.',
      );
      return;
    }

    // ── Phase 2: pick save location ────────────────────────────────────
    // Resolve destination handler.
    final DestinationHandler handler = switch (settings.destination) {
      ExportDestination.file => FileSaver(
        initialDirectory: ref
            .read(globalPreferencesControllerProvider)
            .defaultSaveLocation,
      ),
      ExportDestination.clipboard => ClipboardCopier(),
      ExportDestination.shareableLink => ShareableLinkPublisher(),
    };

    // Build suggested filename: <stem>_export_<ts>.<ext>
    final ext = settings.format == ExportFormat.gif ? '.gif' : '.mp4';
    final src = File(widget.videoPath);
    final stem = src.uri.pathSegments.last.split('.').first;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final suggested = '${stem}_export_$ts$ext';

    // resolveOutputPath is in its own try/catch so that if file_selector
    // throws (sandbox denial, save-panel error) the user sees a clear
    // message — and we haven't shown the progress dialog yet, so there is
    // nothing to pop.
    final String? outPath;
    try {
      outPath = await handler.resolveOutputPath(suggestedFileName: suggested);
    } catch (e) {
      if (!mounted) return;
      AppAlerts.error('Couldn\'t pick a save location: $e');
      return;
    }

    if (outPath == null || !mounted) return;

    // ── Phase 3: encode ────────────────────────────────────────────────
    // Load cursor sidecar (best-effort).
    final cursorRec = await CursorRecording.loadFromFile(
      '${widget.videoPath}.cursor.json',
    ).catchError((_) => CursorRecording());

    if (!mounted) return;

    // Capture the crumb store BEFORE the awaited export below. If the screen
    // is popped mid-export, `ref.read` in the `finally` would throw (element
    // defunct) — skipping progress.dispose() and leaking the notifier. A
    // reference captured here (mirroring captions_tab.dart) stays usable.
    final crumbStore = ref.read(crumbStoreProvider);

    final progress = ValueNotifier<double?>(null);
    try {
      // Fire-and-forget: the dialog is dismissed via Navigator.pop below;
      // we don't need the returned Future<void>.
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            content: SizedBox(
              height: 80,
              child: ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        value == null
                            ? 'Exporting…'
                            : 'Exporting… ${(value * 100).round()}%',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // value=null → indeterminate (the bar bounces) until
                      // we know the frame count; once we do, it switches
                      // to a determinate fill.
                      LinearProgressIndicator(value: value),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      // Run the pipeline + deliver via the headless ExportController. The
      // pipeline is picked by format inside the injected closure; this widget
      // keeps all dialogs/snackbars/Navigator and maps the typed outcome to UI.
      final exportController = ExportController(
        isExportEntitled: () =>
            canExportNow(ref.read(entitlementProvider), appReleaseDate: buildReleaseDate),
        runPipeline: ({required onProgress, required cancelToken}) {
          return settings!.format == ExportFormat.gif
              ? GifExportPipeline(
                  sourcePath: widget.videoPath,
                  outputPath: outPath!,
                  sourceMetadata: meta,
                  cursorRecording: cursorRec,
                  projectState: _project,
                  settings: settings,
                  deviceFrameCatalog: _deviceFrameCatalog,
                  motionTuning: ref.read(motionTuningProvider),
                ).run(onProgress: onProgress, cancelToken: cancelToken)
              : ExportPipeline(
                  sourcePath: widget.videoPath,
                  outputPath: outPath!,
                  sourceMetadata: meta,
                  cursorRecording: cursorRec,
                  projectState: _project,
                  settings: settings,
                  deviceFrameCatalog: _deviceFrameCatalog,
                  motionTuning: ref.read(motionTuningProvider),
                ).run(onProgress: onProgress, cancelToken: cancelToken);
          // N-slice export for both formats: per-slice trim/speed/fade come
          // from state.timeline.clips. The B-era top-level TrimSelection is
          // no longer plumbed into either pipeline.
        },
      );

      ref.read(analyticsServiceProvider).capture(
        AnalyticsEvents.exportStarted,
        properties: {
          'format': settings.format.name,
          'resolution': settings.resolution.name,
          'fps': settings.frameRate,
          'compression': settings.compression.name,
          'destination': settings.destination.name,
        },
      );

      // Right before the native handoff (ffmpeg/gif pipeline spawn below),
      // so a crash in that subprocess is captured with this activity set.
      crumbStore.setActivity({
        'op': 'export',
        'format': settings.format.name,
        'resolution': settings.resolution.name,
      });
      crumbStore.flushNow();

      final outcome = await exportController.run(
        outputPath: outPath,
        handler: handler,
        onProgress: (p) => progress.value = p,
      );

      if (!mounted) return;
      Navigator.of(context).pop(); // close progress dialog

      switch (outcome) {
        case ExportSuccess(:final summary, :final result):
          ref.read(analyticsServiceProvider).capture(
            AnalyticsEvents.exportCompleted,
            properties: {
              'format': settings.format.name,
              'resolution': settings.resolution.name,
              'fps': settings.frameRate,
              'realtime_multiple': summary.realtimeMultiple,
            },
          );
          // Persist settings minus the title (plan rule 5).
          await store.save(settings.copyWith(clearTitle: true));

          // Normalize the observed realtime multiplier to the estimator's
          // baseline (1080p @ 30fps) and persist it so the next dialog
          // open uses the actual hardware rate. Skipped for GIF because
          // its two-pass pipeline costs are dominated by palette work,
          // not the linear pixels-per-second model the estimator assumes.
          if (settings.format == ExportFormat.mp4 &&
              summary.realtimeMultiple > 0) {
            final outDims = settings.resolution.dimensionsFor(
              composedVideoSize,
            );
            final outArea = outDims.width * outDims.height;
            final fpsScale = settings.frameRate / kBaselineFrameRate;
            final areaScale = outArea / kBaselineAreaPixels;
            final normalized = summary.realtimeMultiple * fpsScale * areaScale;
            unawaited(telemetryStore.saveRealtimeMultiplier(normalized));
          }

          if (!mounted) return;
          // Record the export path so the reveal-in-Finder button lights up
          // the next time the dialog is opened.
          setState(() => _lastExportPath = outPath);

          AppAlerts.success(
            result.message,
            action: result.revealPath != null
                ? AppAlertAction(
                    label: 'Show in Finder',
                    onPressed: () {
                      // macOS-only: reveal in Finder. No-op on other platforms.
                      if (Platform.isMacOS) {
                        unawaited(
                          Process.run('open', [
                            '-R',
                            result.revealPath!,
                          ]).catchError((_) => ProcessResult(0, 1, '', '')),
                        );
                      }
                    },
                  )
                : null,
          );
          surfaceExportWarnings(summary, (m) => AppAlerts.warning(m));
        case ExportFailure(:final error, :final stackTrace):
          // Only the error's type — never the message, which can contain file
          // paths.
          ref.read(analyticsServiceProvider).capture(
            AnalyticsEvents.exportFailed,
            properties: {
              'format': settings.format.name,
              'error_type': error.runtimeType.toString(),
            },
          );
          ref.read(diagnosticsServiceProvider).captureException(
            error,
            stackTrace ?? StackTrace.current,
            handled: true,
            messageOverride: error.runtimeType.toString(),
            context: {'phase': 'export', 'format': settings.format.name},
          );
          AppAlerts.error('Export failed: $error');
        case ExportNotEntitled():
          ref.read(analyticsServiceProvider).capture(
            AnalyticsEvents.exportFailed,
            properties: {'reason': 'not_entitled'},
          );
          AppAlerts.error('Export needs an active license.');
        case ExportCancelled():
          // No snackbar — user-initiated. (Today there's no cancel UI; this
          // arm is here for when a cancel button is wired to
          // exportController.cancel().)
          break;
      }
    } finally {
      // Covers every exit from the encode phase (success, failure, cancel,
      // not-entitled, or an uncaught exception) — the export op has ended.
      // Dispose the notifier FIRST and unconditionally so it can never be
      // skipped (and leaked) by a throw from the crumb-store call. `crumbStore`
      // was captured before the await, so it stays valid even if this screen
      // was popped mid-export.
      progress.dispose();
      crumbStore.setActivity(null);
    }
  }

  void _togglePlayPause() {
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
      } else {
        _controller.play();
      }
    });
  }

  // Updates the user's intended position whenever the controller's
  // value changes AND we're not in the middle of a hover-scrub (the
  // controller drops the update while hovering). Driven by the player
  // listener — intentionally does NOT setState (mirrors the old
  // _trackIntendedPosition).
  // Track the SMOOTHED playhead, not the controller's raw position poll. The
  // poll lags playback and freezes on pause, so anchoring the hover position
  // to it makes the playhead snap backward when a hover preview starts (the
  // marker renders at the anchor while hovering) and when it restores on hover
  // end. The smoothed value is the accurate, held position. On pause the
  // smooth controller updates _smoothed before this fires (it listens first),
  // so the anchor captured here is the frozen-at-pause position.
  void _onHoverTrack() =>
      _hover.track(_smoothPlayhead?.position ?? _controller.value.position);

  void _seekToStart() {
    setState(() => _hover.seekToStart());
    _refreshPlayheadEditedPos();
  }

  void _seekToEnd() {
    setState(() => _hover.seekToEnd(_controller.value.duration));
    _refreshPlayheadEditedPos();
  }

  /// `m:ss.hh` — used in the transport bar where the playhead's
  /// hundredths matter (frame-accurate scrubbing feedback).
  String _formatPreciseDuration(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final hundredths = ((d.inMilliseconds % 1000) ~/ 10).toString().padLeft(
      2,
      '0',
    );
    return '$m:$s.$hundredths';
  }

  @override
  Widget build(BuildContext context) {
    // Publish the controller for VM-service playback control (debug
    // only). Set in build so a hot-reload re-establishes it without a
    // full restart. See [debugPlaybackController].
    assert(() {
      debugPlaybackController = _controller;
      return true;
    }());
    // Single source of truth: every editor-state read in the body
    // pulls from this snapshot. Rebuilds when any notifier mutator
    // publishes — matches the previous setState-driven rebuild scope.
    final project = ref.watch(editorProjectControllerProvider);
    // Auto-persist: any mutation on the notifier triggers the
    // debounced save in [_persistProject]. Replaces ~30 inline
    // `_persistProject()` calls scattered through the inspector
    // callbacks.
    ref.listen<EditorProjectState>(
      editorProjectControllerProvider,
      (_, __) => _persistProject(),
    );
    // When the clip list changes (any slice's speed edited, slices
    // added/removed, trims changed), re-evaluate the player rate
    // against the slice the playhead is currently inside. Force the
    // slice-index cache to -1 so [_onSpeedTick] re-applies on the very
    // next tick even when the active slice's INDEX is unchanged but
    // its speed was edited in place. Preview rate = sliceSpeed ×
    // _previewPlaybackSpeed.
    ref.listen<List<ClipSlice>>(
      editorProjectControllerProvider.select((s) => s.timeline.clips),
      (_, __) {
        if (!_isInitialized) return;
        _currentSliceIndex = -1;
        _applyEffectivePlaybackSpeed(
          _effectiveClipSpeedAt(_controller.value.position),
        );
        // Trims / splits / merges change the source→edited mapping; the
        // smooth-playhead listener won't refresh while paused, so push
        // an explicit update here.
        _refreshPlayheadEditedPos();
      },
    );
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        // Only handle key down events
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }

        final isMac = Platform.isMacOS;
        // The MODIFIER state (is Cmd / Ctrl currently held?), not the
        // identity of the key that fired this event. Cmd+Z fires a
        // `keyZ` event with Cmd held — the previous check compared the
        // event's logicalKey to meta/control which is only ever true
        // when the modifier itself is what was just pressed, so every
        // Cmd-prefixed shortcut below was silently ignored.
        final cmdOrCtrl = isMac
            ? HardwareKeyboard.instance.isMetaPressed
            : HardwareKeyboard.instance.isControlPressed;

        // Undo: Cmd+Z (Mac) or Ctrl+Z (Windows/Linux)
        if (cmdOrCtrl &&
            event.logicalKey == LogicalKeyboardKey.keyZ &&
            !HardwareKeyboard.instance.isShiftPressed) {
          if ((_history?.canUndo ?? false)) {
            _handleUndo();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // Redo: Cmd+Shift+Z (Mac) or Ctrl+Shift+Z (Windows/Linux)
        if (cmdOrCtrl &&
            event.logicalKey == LogicalKeyboardKey.keyZ &&
            HardwareKeyboard.instance.isShiftPressed) {
          if ((_history?.canRedo ?? false)) {
            _handleRedo();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // Space: Play/Pause toggle — route through the same handler the
        // play/pause button uses so the icon and dependent UI refresh
        // identically (the old inline play/pause skipped setState).
        if (event.logicalKey == LogicalKeyboardKey.space) {
          _togglePlayPause();
          return KeyEventResult.handled;
        }

        // Cmd/Ctrl+Left → first frame, Cmd/Ctrl+Right → last frame.
        if (cmdOrCtrl && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _seekToStart();
          return KeyEventResult.handled;
        }
        if (cmdOrCtrl && event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _seekToEnd();
          return KeyEventResult.handled;
        }

        return KeyEventResult.ignored;
      },
      child: Shortcuts(
        shortcuts: buildZoomShortcuts(),
        child: Actions(
          actions: buildZoomActions(
            getScale: () =>
                ref.read(editorProjectControllerProvider).timelineScale,
            setScale: (next) => ref
                .read(editorProjectControllerProvider.notifier)
                .setTimelineScale(next, anchorTime: _controller.value.position),
          ),
          child: Scaffold(
            backgroundColor: context.palette.appBackground,
            appBar: _buildTopBar(context),
            body: Column(
              children: [
                // Preview backdrop on the left, inspector panel on the right.
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            Divider(
                              height: 1,
                              thickness: 1,
                              color: context.palette.dividerSubtle,
                            ),
                            CanvasToolbar(
                              children: [
                                AspectRatioPicker(
                                  current: project.outputAspect,
                                  onChanged: (v) => ref
                                      .read(
                                        editorProjectControllerProvider
                                            .notifier,
                                      )
                                      .setOutputAspect(v),
                                ),
                              ],
                            ),
                            Expanded(
                              child: Stack(
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          context.palette.surfaceLow,
                                          context.palette.appBackground,
                                        ],
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: _buildVideoPlayer(),
                                  ),
                                  // Zoom debug readout — rendered at the top-left
                                  // of the preview pane, OUTSIDE the playback
                                  // canvas's zoom Transform so the text stays
                                  // anchored even when the video is zoomed in
                                  // and the canvas content slides off-screen.
                                  if (_showZoomDebug)
                                    Positioned(
                                      top: 12,
                                      left: 12,
                                      child:
                                          ValueListenableBuilder<
                                            ZoomDebugSnapshot?
                                          >(
                                            valueListenable: _zoomDebugSnapshot,
                                            builder: (context, snap, _) {
                                              if (snap == null) {
                                                return const SizedBox.shrink();
                                              }
                                              return ZoomDebugReadoutPanel(
                                                cursor: snap.cursor,
                                                smoothedFocal:
                                                    snap.smoothedFocal,
                                                activeZoom: snap.activeZoom,
                                                inFlight: snap.inFlight,
                                                focalVelocity:
                                                    snap.focalVelocity,
                                                cursorVelocity:
                                                    snap.cursorVelocity,
                                                videoSize: snap.videoSize,
                                                cursorSampleCount:
                                                    snap.cursorSampleCount,
                                                position: snap.position,
                                                cursorXRange: snap.cursorXRange,
                                                cursorYRange: snap.cursorYRange,
                                                lastSnapReason:
                                                    snap.lastSnapReason,
                                                lastSnapAt: snap.lastSnapAt,
                                              );
                                            },
                                          ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_isInitialized && _showSidebar)
                        VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: context.palette.dividerSubtle,
                        ),
                      if (_isInitialized && _showSidebar)
                        InspectorPanel(
                          selection: _currentSelection(),
                          zoomRegions: project.zoomRegions,
                          clipDuration: _controller.value.duration,
                          canHideCursor:
                              _metadata?.isPureSource == true &&
                              _cursorRecording.count > 0,
                          hasKeystrokeData: _keystrokeRecording.count > 0,
                          isDevice: _metadata?.isDeviceCapture == true,
                          curveLibrary: _curveLibrary,
                          onZoomChanged: (i, next) {
                            _zoomPreviewOverride.value = null;
                            final vs = _videoSize();
                            final paddingBefore = _projectController
                                .current
                                .windowFrame
                                .padding
                                .left;
                            _projectController.updateZoomAt(
                              i,
                              next,
                              videoSize: vs,
                            );
                            final paddingAfter = _projectController
                                .current
                                .windowFrame
                                .padding
                                .left;
                            if (paddingAfter > paddingBefore) {
                              AppAlerts.info(
                                '3D zoom needs breathing room — padding set to ${paddingAfter.toStringAsFixed(0)}px',
                              );
                            }
                          },
                          onZoomDeleted: (index) {
                            _projectController.removeZoomAt(index);
                            _setSelectedZoomIndex(null);
                          },
                          onZoomLookAppliedToAll: (look) {
                            _zoomPreviewOverride.value = null;
                            final vs = _videoSize();
                            final paddingBefore = _projectController
                                .current
                                .windowFrame
                                .padding
                                .left;
                            _projectController.applyLookToAllZooms(
                              look,
                              videoSize: vs,
                            );
                            final paddingAfter = _projectController
                                .current
                                .windowFrame
                                .padding
                                .left;
                            if (paddingAfter > paddingBefore) {
                              AppAlerts.info(
                                '3D zoom needs breathing room — padding set to ${paddingAfter.toStringAsFixed(0)}px',
                              );
                            }
                            final count = _projectController
                                .current
                                .zoomRegions
                                .length;
                            AppAlerts.success(
                              'Applied to $count zoom${count == 1 ? '' : 's'}. New zooms will use this look.',
                            );
                          },
                          onZoomEffectChanged: _revealZoomEffect,
                          onSelectionCleared: () {
                            _zoomPreviewOverride.value = null;
                            setState(() {
                              _selectedZoomIndex = null;
                              _selectedSliceIndex = null;
                              _selectedCameraIndex = null;
                            });
                          },
                          hasCamera: _hasCamera,
                          cameraRegions: _hasCamera
                              ? project.cameraRegions
                              : const [],
                          cameraCanvasAspect: () {
                            final vs = _videoSize();
                            if (vs.isEmpty) return 16 / 9;
                            final cs = OutputCanvasResolver.resolve(
                              videoSize: vs,
                              padding: project.windowFrame.padding,
                              aspect: project.outputAspect,
                            ).canvasSize;
                            return cs.height == 0
                                ? 16 / 9
                                : cs.width / cs.height;
                          }(),
                          cameraOriginalAspect:
                              _cameraMeta == null || _cameraMeta!.height == 0
                              ? 1.0
                              : _cameraMeta!.width / _cameraMeta!.height,
                          onCameraChanged: (i, next) =>
                              _projectController.updateCameraRegionAt(i, next),
                          onCameraDeleted: (index) {
                            _projectController.removeCameraRegionAt(index);
                            setState(() => _selectedCameraIndex = null);
                          },
                          onSliceRemoved: (removed) {
                            setState(() {
                              _selectedSliceIndex = decrementSelectionOnRemoval(
                                selected: _selectedSliceIndex,
                                removed: removed,
                              );
                            });
                          },
                          videoSize: _videoSize(),
                          videoPath: widget.videoPath,
                          // Only resolve the composed-canvas geometry (an
                          // OutputCanvasResolver pass + device-catalog lookup)
                          // when a zoom is actually selected and its placement
                          // picker can be shown — skip the work on every
                          // unrelated rebuild.
                          placementGeometry: _selectedZoomIndex != null
                              ? _placementGeometry(project)
                              : null,
                          onPlacementPreview: _onPlacementPreview,
                          onPlacementCommit: _onPlacementCommit,
                        ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: context.palette.dividerSubtle,
                ),
                _buildControls(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoPlayer() {
    if (_error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 64, color: Colors.red),
          const SizedBox(height: 16),
          const Text(
            'Error loading video',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _error!,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    if (!_isInitialized) {
      return CircularProgressIndicator(color: context.palette.accent);
    }

    // isHovering is set on the first hover-seek and cleared on
    // hover-end / committed seek. It's a precise "we're scrubbing,
    // not playing" signal — the canvas uses it to bypass stateful
    // smoothers (EMA velocity, focal tween) so forward and backward
    // hover render the same frame at the same timestamp.
    final isHoverScrubbing = _hover.isHovering;
    // PlaybackCanvas owns the production scene pass so it can keep the cursor
    // overlay outside the captured video/body layer. This avoids applying the
    // camera smear on top of the cursor's own accumulation trail.
    final project = ref.watch(editorProjectControllerProvider);
    final masterCurved = sceneBlurMasterResponse(project.motionBlur);
    final screenMovementCurved = sceneBlurChannelResponse(
      project.screenMovementBlur,
    );
    final screenZoomCurved = sceneBlurChannelResponse(project.screenZoomBlur);
    final currentSlice = clipSliceAt(
      project.timeline.clips,
      _controller.value.position,
    );
    final playbackCanvas = PlaybackCanvas(
      controller: _controller,
      smoothPlayhead: _smoothPlayhead,
      displayLatency: _latencyProbe?.latency,
      frame: project.windowFrame,
      outputAspect: project.outputAspect,
      metadata: _metadata,
      cursorRecording: _cursorRecording,
      hideCursorOverlay: project.hideCursorOverlay,
      sliceHideCursor: currentSlice.hideCursor,
      sliceDisableSmoothMouse: currentSlice.disableSmoothMouse,
      clips: project.timeline.clips,
      cursorSize: project.cursorSize,
      cursorStyle: project.cursorStyle,
      cursorClickEffect: project.cursorClickEffect,
      showZoomDebug: _showZoomDebug,
      debugSnapshot: _zoomDebugSnapshot,
      zoomRegions: project.zoomRegions,
      screenAnimationConfig: project.screenAnimationConfig,
      cursorAnimationConfig: project.cursorAnimationConfig,
      motionBlur: project.motionBlur,
      sceneMotionBlur: masterCurved,
      cursorMovementBlur: project.cursorMovementBlur,
      screenMovementBlur: screenMovementCurved,
      screenZoomBlur: screenZoomCurved,
      // motionBlurTuning is required by PlaybackCanvas's API only
      // because the legacy `CursorBlurMode.shader` path uses it.
      // Production uses accumulation, which ignores it, so passing
      // the defaults is purely to satisfy the constructor.
      motionBlurTuning: MotionBlurTuning.defaults,
      // Production cursor blur uses the same path-stamped
      // accumulation the playground's scene mode uses — no shader
      // tuning required, the Cursor movement knob alone controls it.
      cursorBlurMode: CursorBlurMode.accumulation,
      // Base cursor exposure. PlaybackCanvas's default is 40 ms,
      // which combined with the new master cap (0..0.5) caps the
      // effective cursor exposure at 20 ms — a ~10 px trail at
      // typical UI velocity, so subtle the master slider's range
      // feels like a binary on/off. 150 ms matches the playground's
      // working tuning scaled for production's smaller default
      // cursor (2× here vs 4× in the playground); master at 50%
      // now produces a clearly visible ~75 ms trail and the slider
      // gives a usable gradient.
      accumulationExposureMs: kCursorBlurBaseExposureMs,
      cursorShadow: project.cursorShadow,
      clickSpring: project.clickSpring,
      cursorDelay: project.cursorDelay,
      isHoverScrubbing: isHoverScrubbing,
      cursorPostProcess: project.cursorPostProcess,
      zoomPreviewOverride: _zoomPreviewOverride,
      keystrokeRecording: _keystrokeRecording,
      keystrokeOverlaySettings: project.keystrokeOverlay,
      captionSegments: project.captions,
      captionStyle: project.captionStyle,
      cameraController: _cameraController,
      cameraSettings: _hasCamera ? project.cameraSettings : null,
      cameraRegions: _hasCamera ? project.cameraRegions : const [],
      cameraOriginalAspect: _cameraMeta == null || _cameraMeta!.height == 0
          ? 1.0
          : _cameraMeta!.width / _cameraMeta!.height,
      selectedCameraIndex: _selectedCameraIndex,
      cameraDragOverride: _cameraDragOverride,
      // Per pointer-move: push the live placement to the override only (the
      // canvas rebuilds, the rest of the editor doesn't).
      onCameraPlacementChanged: (index, placement) {
        _cameraDragOverride.value = (index: index, placement: placement);
      },
      // On drag end: commit the previewed placement to project state once.
      onCameraPlacementCommit: () {
        final o = _cameraDragOverride.value;
        _cameraDragOverride.value = null;
        if (o == null) return;
        final regions = _project.cameraRegions;
        if (o.index < 0 || o.index >= regions.length) return;
        _projectController.updateCameraRegionAt(
          o.index,
          regions[o.index].copyWith(
            centerX: o.placement.centerX,
            centerY: o.placement.centerY,
            size: o.placement.size,
          ),
        );
      },
      onCameraSelectRequested: (index) {
        if (index == _selectedCameraIndex) return;
        setState(() {
          _selectedCameraIndex = index;
          _selectedZoomIndex = null;
          _selectedSliceIndex = null;
        });
      },
      deviceFrameCatalog: _deviceFrameCatalog,
    );

    // Production uses PlaybackCanvas's internal scene pass. That pass captures
    // only the moving video/body; the cursor remains a separate transformed
    // overlay, so its accumulation trail is never smeared a second time by the
    // camera shader. Export uses the same layer split.
    return playbackCanvas;
  }

  /// Compact transport bar shown above the timeline:
  ///   `[ start-time ]  ⏮  ▶  ⏭  [ end-time ]`
  ///
  /// Each button has a tooltip with its keyboard shortcut. Time labels
  /// use `m:ss.hh` precision so the user gets frame-level feedback.
  Widget _buildTransportBar() {
    final isMac = Platform.isMacOS;
    final modKey = isMac ? '⌘' : 'Ctrl';
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, _smoothPlayhead]),
      builder: (context, _) {
        final sourcePos = _hover.isHovering
            ? _hover.intendedPosition
            : (_smoothPlayhead?.position ?? _controller.value.position);
        // Transport readout shows edited time so the numbers track the
        // timeline x-axis: per-slice playbackSpeed compresses/expands the
        // contribution to total, and the current-time ticks at the rate
        // the user sees the playhead move.
        final clips = ref.watch(editorProjectControllerProvider).timeline.clips;
        final pos = clips.isEmpty
            ? sourcePos
            : sourceToEdited(clips, sourcePos);
        final dur = clips.isEmpty
            ? _controller.value.duration
            : totalEditedDuration(clips);
        final isPlaying = _controller.value.isPlaying;
        // Stack lets the play-controls Row stay perfectly centered
        // while the zoom slider + preview-speed dropdown right-aligns
        // independently. Both children share the same vertical extent,
        // so the slider stays visually aligned with the play button.
        return Stack(
          alignment: Alignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    _formatPreciseDuration(pos),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                TransportButton(
                  icon: Icons.skip_previous,
                  tooltip: 'Go to first frame',
                  shortcut: '$modKey ←',
                  onPressed: _seekToStart,
                ),
                const SizedBox(width: 16),
                TransportPlayButton(
                  isPlaying: isPlaying,
                  onPressed: _togglePlayPause,
                ),
                const SizedBox(width: 16),
                TransportButton(
                  icon: Icons.skip_next,
                  tooltip: 'Go to last frame',
                  shortcut: '$modKey →',
                  onPressed: _seekToEnd,
                ),
                const SizedBox(width: 24),
                SizedBox(
                  width: 64,
                  child: Text(
                    _formatPreciseDuration(dur),
                    textAlign: TextAlign.left,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: 'Cut tool (Esc to exit)',
                    child: IconButton(
                      icon: const Icon(Icons.content_cut, size: 18),
                      isSelected: _cutModeActive,
                      color: _cutModeActive
                          ? const Color(0xFF6C63FF)
                          : Colors.white70,
                      onPressed: () =>
                          setState(() => _cutModeActive = !_cutModeActive),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TimelineScaleSlider(
                    playheadPosition: pos,
                    previewPlaybackSpeed: _previewPlaybackSpeed,
                    onPreviewSpeedChanged: (s) {
                      setState(() {
                        _previewPlaybackSpeed = s;
                      });
                      _applyEffectivePlaybackSpeed(_lastClipSpeedApplied);
                    },
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildControls() {
    if (_error != null || !_isInitialized) {
      return const SizedBox.shrink();
    }
    // Top-bar "View" menu toggle. Collapses the whole transport +
    // timeline block; the canvas above naturally expands to fill the
    // freed vertical space.
    if (!_showTimeline) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: BoxDecoration(
        color: context.palette.surfaceCard,
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 8,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _buildTransportBar(),
          ),
          const SizedBox(height: 12),

          // Stacked timeline (time ruler + clip lane + zoom lane).
          //
          // `animation: _controller` (was `Listenable.merge([_controller,
          // _smoothPlayhead])`) — _smoothPlayhead used to drive this
          // builder per vsync, rebuilding the entire timeline subtree
          // at 60 Hz. Position now flows into EditorTimeline through
          // [_playheadEditedPos] via ValueListenableBuilder, so this
          // builder only needs to fire on controller events
          // (play/pause/duration/seek, ~4 Hz steady-state).
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              // The timeline's x-axis is edited time: ruler width =
              // total edited duration, scrub callbacks deliver edited
              // and we convert back to source before seeking the
              // controller. The playhead position itself rides the
              // [_playheadEditedPos] notifier, not this builder.
              final clipsForTimeline = ref
                  .watch(editorProjectControllerProvider)
                  .timeline
                  .clips;
              final editedDuration = clipsForTimeline.isEmpty
                  ? _controller.value.duration
                  : totalEditedDuration(clipsForTimeline);
              final audioRoles = inferAudioRoles(
                ref.watch(recordingAudioStreamsProvider),
              );
              return EditorTimeline(
                duration: editedDuration,
                position: _playheadEditedPos,
                isPlaying: _controller.value.isPlaying,
                timelineScale: ref
                    .watch(editorProjectControllerProvider)
                    .timelineScale,
                pendingScaleAnchor: ref
                    .watch(editorProjectControllerProvider)
                    .pendingScaleAnchor,
                onAnchorConsumed: () => ref
                    .read(editorProjectControllerProvider.notifier)
                    .clearPendingScaleAnchor(),
                onPinchScale: (newScale, anchor) => ref
                    .read(editorProjectControllerProvider.notifier)
                    .setTimelineScale(newScale, anchorTime: anchor),
                onSeek: (editedNext) {
                  // EditorTimeline emits edited-time positions; convert
                  // to source before feeding the controller-bound hover
                  // chain so the controller seeks to the correct frame.
                  final sourceNext = _editedSeekToSource(editedNext);
                  setState(() {
                    _hover.seek(sourceNext);
                    // A committed seek on empty timeline (ruler or the
                    // empty lane area) is a "click anywhere" — deselect
                    // slice, zoom, and camera so the inspector returns to
                    // its default state. A tap ON a bar routes through
                    // onSeekKeepSelection instead and preserves selection.
                    _selectedSliceIndex = null;
                    _selectedZoomIndex = null;
                    _selectedCameraIndex = null;
                  });
                  _refreshPlayheadEditedPos();
                  _checkZoomMarkerClick(sourceNext);
                },
                onSeekKeepSelection: (editedNext) {
                  // A tap that landed ON a slice/zoom/camera bar: the bar's
                  // own handler selects it; here we only move the playhead,
                  // so one click both seeks and selects. Leave selection and
                  // the zoom-marker check to the bar's handler.
                  final sourceNext = _editedSeekToSource(editedNext);
                  setState(() => _hover.seek(sourceNext));
                  _refreshPlayheadEditedPos();
                },
                onHoverSeek: (editedNext) {
                  // Mark hover active so the listener stops updating
                  // the anchor. The anchor we'll restore to on
                  // hover-end is whatever the listener last wrote — i.e.
                  // the user's actual stopped position. Convert edited
                  // → source so the controller seeks the right frame.
                  final clips = ref
                      .read(editorProjectControllerProvider)
                      .timeline
                      .clips;
                  final sourceNext = clips.isEmpty
                      ? editedNext
                      : seekFromEditedTime(clips, editedNext);
                  setState(() => _hover.hoverSeek(sourceNext));
                  _refreshPlayheadEditedPos();
                },
                onHoverEnd: () {
                  setState(() => _hover.hoverEnd());
                  _refreshPlayheadEditedPos();
                },
                zoomRegions: _project.zoomRegions,
                selectedZoomIndex: _selectedZoomIndex,
                onZoomSelected: (i) {
                  if (i != _selectedZoomIndex) {
                    _zoomPreviewOverride.value = null;
                  }
                  setState(() {
                    _selectedZoomIndex = i;
                    // Zoom, slice, and camera selections are mutually
                    // exclusive — selecting a zoom clears the others.
                    if (i != null) {
                      _selectedSliceIndex = null;
                      _selectedCameraIndex = null;
                    }
                  });
                },
                onZoomChanged: (i, next) {
                  _zoomPreviewOverride.value = null;
                  final vs = _videoSize();
                  final paddingBefore =
                      _projectController.current.windowFrame.padding.left;
                  _projectController.updateZoomAt(i, next, videoSize: vs);
                  final paddingAfter =
                      _projectController.current.windowFrame.padding.left;
                  if (paddingAfter > paddingBefore) {
                    AppAlerts.info(
                      '3D zoom needs breathing room — padding set to ${paddingAfter.toStringAsFixed(0)}px',
                    );
                  }
                },
                onZoomDeleted: (index) {
                  _projectController.removeZoomAt(index);
                  _zoomPreviewOverride.value = null;
                  setState(() {
                    if (_selectedZoomIndex == index) {
                      _selectedZoomIndex = null;
                    } else if (_selectedZoomIndex != null &&
                        _selectedZoomIndex! > index) {
                      _selectedZoomIndex = _selectedZoomIndex! - 1;
                    }
                  });
                },
                onZoomAdded: _addZoomAt,
                cameraRegions: _hasCamera ? _project.cameraRegions : const [],
                selectedCameraIndex: _selectedCameraIndex,
                onCameraSelected: (i) {
                  setState(() {
                    _selectedCameraIndex = i;
                    if (i != null) {
                      _selectedZoomIndex = null;
                      _selectedSliceIndex = null;
                    }
                  });
                },
                onCameraChanged: (i, next) =>
                    _projectController.updateCameraRegionAt(i, next),
                onCameraDeleted: (index) {
                  _projectController.removeCameraRegionAt(index);
                  setState(() {
                    if (_selectedCameraIndex == index) {
                      _selectedCameraIndex = null;
                    } else if (_selectedCameraIndex != null &&
                        _selectedCameraIndex! > index) {
                      _selectedCameraIndex = _selectedCameraIndex! - 1;
                    }
                  });
                },
                onCameraAdded: _addCameraAt,
                showCameraLane: _hasCamera,
                clips: ref
                    .watch(editorProjectControllerProvider)
                    .timeline
                    .clips,
                selectedSliceIndex: _selectedSliceIndex,
                onSliceSelected: (idx) {
                  setState(() {
                    _selectedSliceIndex = idx;
                    if (idx != null) {
                      _selectedZoomIndex = null;
                      _selectedCameraIndex = null;
                    }
                  });
                },
                onSliceTrimStartChanged: (idx, v) => ref
                    .read(editorProjectControllerProvider.notifier)
                    .setSliceTrimStart(idx, v),
                onSliceTrimEndChanged: (idx, v) => ref
                    .read(editorProjectControllerProvider.notifier)
                    .setSliceTrimEnd(idx, v),
                onClearSeamTrims: (seamIndex) => ref
                    .read(editorProjectControllerProvider.notifier)
                    .clearSeamTrims(seamIndex),
                onClearStartTrim: () {
                  final ctl = ref.read(
                    editorProjectControllerProvider.notifier,
                  );
                  final clips = ref
                      .read(editorProjectControllerProvider)
                      .timeline
                      .clips;
                  if (clips.isEmpty) return;
                  ctl.setSliceTrimStart(0, clips.first.cutStart);
                },
                onClearEndTrim: () {
                  final ctl = ref.read(
                    editorProjectControllerProvider.notifier,
                  );
                  final clips = ref
                      .read(editorProjectControllerProvider)
                      .timeline
                      .clips;
                  if (clips.isEmpty) return;
                  ctl.setSliceTrimEnd(clips.length - 1, clips.last.cutEnd);
                },
                onMergeSeam: (seamIndex) {
                  // Adjust selection BEFORE merging, while indices still
                  // reflect the pre-merge clip list:
                  //  - selection == seamIndex + 1 -> moves to seamIndex
                  //    (the merged slice keeps the left index).
                  //  - selection > seamIndex + 1 -> shifts left by 1.
                  //  - selection == seamIndex -> unchanged.
                  //  - selection < seamIndex or null -> unchanged.
                  setState(() {
                    final sel = _selectedSliceIndex;
                    if (sel != null) {
                      if (sel == seamIndex + 1) {
                        _selectedSliceIndex = seamIndex;
                      } else if (sel > seamIndex + 1) {
                        _selectedSliceIndex = sel - 1;
                      }
                    }
                  });
                  ref
                      .read(editorProjectControllerProvider.notifier)
                      .mergeSeam(seamIndex);
                },
                cutModeActive: _cutModeActive,
                onCutModeChanged: (v) => setState(() => _cutModeActive = v),
                playheadFlashOn: _playheadFlashOn,
                cursorClickTimes: _cursorRecording.eventIndex.clickTimes,
                onSnapped: _flashSnap,
                snapFlashTarget: _snapFlashTarget,
                keystrokeRecording: _keystrokeRecording,
                keystrokeSettings: ref
                    .watch(editorProjectControllerProvider)
                    .keystrokeOverlay,
                onKeystrokeToggle: _toggleKeystrokeGroup,
                // cursorXListenable stays unset — when cut mode is on,
                // EditorTimeline pipes its own overlay's cursor in. Off
                // mode falls back to a no-op notifier.
                waveform: ref
                    .watch(waveformProvider(widget.videoPath))
                    .valueOrNull,
                hasMic: audioRoles.containsKey(AudioRole.microphone),
                hasSystem: audioRoles.containsKey(AudioRole.system),
              );
            },
          ),

          const SizedBox(height: 8),

          // Undo/Redo and Zoom buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Undo button
              IconButton(
                onPressed: (_history?.canUndo ?? false) ? _handleUndo : null,
                icon: const Icon(Icons.undo),
                tooltip: 'Undo (Cmd+Z)',
                color: context.palette.accent,
                disabledColor: Colors.white24,
              ),

              // Redo button
              IconButton(
                onPressed: (_history?.canRedo ?? false) ? _handleRedo : null,
                icon: const Icon(Icons.redo),
                tooltip: 'Redo (Cmd+Shift+Z)',
                color: context.palette.accent,
                disabledColor: Colors.white24,
              ),

              // Dev HUD toggle: shows the recorded cursor position
              // overlaid on the video so we can verify the zoom focal
              // is following it.
              IconButton(
                onPressed: () =>
                    setState(() => _showZoomDebug = !_showZoomDebug),
                icon: const Icon(Icons.gps_fixed),
                color: _showZoomDebug ? context.palette.accent : Colors.white38,
                tooltip: _showZoomDebug ? 'Hide cursor HUD' : 'Show cursor HUD',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Actions emitted by the top-bar "View" drop-down. Two toggles
/// (sidebar / timeline visibility) and an action placeholder for the
/// future preview mode.
enum _ViewMenuAction { sidebar, timeline, preview }
