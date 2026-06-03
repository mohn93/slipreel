import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_history_controller.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:video_player/video_player.dart';
import 'package:slipreel_engine/effects/accumulation_cursor_painter.dart' show CursorBlurMode;
import 'package:slipreel_engine/effects/motion_blur_tuning.dart';
import 'package:slipreel_engine/models/trim_selection.dart';
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
import 'package:screen_recorder/ui/widgets/inspector/timeline_selection.dart';
import 'package:screen_recorder/ui/widgets/transport/transport_buttons.dart';
import 'package:screen_recorder/ui/widgets/scene_blur_overlay.dart';
import 'package:screen_recorder/ui/widgets/zoom/playback_canvas.dart';
import 'package:screen_recorder/state/zoom_preview_override.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/aspect_ratio_picker.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/canvas_toolbar.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/snap_toggle_pill.dart';
import 'package:screen_recorder/ui/widgets/canvas_toolbar/timeline_scale_slider.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_debug_painter.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/export_dialog.dart';
import 'package:screen_recorder/ui/screens/settings_screen.dart';
import 'package:screen_recorder/ui/screens/zoom_shortcuts.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';
import 'package:slipreel_engine/export/gif_export_pipeline.dart';
import 'package:slipreel_engine/export/ffmpeg_probe.dart';
import 'package:slipreel_engine/export/audio_mix_args.dart';
import 'package:slipreel_engine/state/audio_mix.dart';
import 'package:slipreel_engine/editor/auto_zoom_detector.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
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
import 'package:screen_recorder/state/snap_preference_controller.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';

/// Debug hook: the active [PlaybackScreen] publishes its video
/// controller here (in debug/profile builds) so VM-service extensions
/// (`ext.slipreel.*`, registered in main.dart) can drive playback —
/// play / pause / seek / read state — during agent-driven debugging
/// without needing to find and tap the transport buttons. Null when no
/// editor is open.
VideoPlayerController? debugPlaybackController;

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
}) =>
    controller.splitAtPlayhead(currentEditedTime, clips);

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
double effectiveClipSpeedAt(
  List<ClipSlice> clips,
  Duration sourcePosition,
) {
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
  EditorProjectState get _project =>
      ref.read(editorProjectControllerProvider);
  EditorProjectController get _projectController =>
      ref.read(editorProjectControllerProvider.notifier);

  RecordingMetadata? _metadata;
  CursorRecording _cursorRecording = CursorRecording();
  // Owns hover-scrub state: the user's intended (anchor) position —
  // the spot we return to when a hover-preview ends — and whether a
  // hover-preview is in progress. The anchor is updated continuously
  // while NOT hover-scrubbing (so it tracks playback and committed
  // seeks) and frozen while hovering (so hover seeks don't overwrite
  // it with previewed positions). The colored playhead and time
  // labels display the frozen anchor while hovering; PlaybackCanvas /
  // SceneBlurOverlay receive `isHovering` as `isHoverScrubbing` so
  // their stateful smoothers bypass. Wired in [_initializeVideo] once
  // the controller is initialised. setState is owned by this widget:
  // it wraps the controller's mutating methods at the call sites.
  late final HoverScrubController _hover;
  // Dev HUD: when on, draws a marker at the recorded cursor's video-pixel
  // position so we can visually confirm the zoom focal is tracking it.
  bool _showZoomDebug = false;
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

  @override
  void initState() {
    super.initState();
    _initializeVideo();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  /// Global Cmd+K → split at the current playhead's edited time.
  /// Success: clear slice selection. Failure: flash the playhead pill.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final isCmdK = event.logicalKey == LogicalKeyboardKey.keyK &&
        HardwareKeyboard.instance.isMetaPressed;
    if (!isCmdK) return false;
    // Need an initialised controller to read the playhead. Bail
    // quietly so the keypress falls through to system handling.
    if (!_isInitialized) return false;
    final clips = ref.read(editorProjectControllerProvider).timeline.clips;
    final sourcePos = _controller.value.position;
    final editedPos = sourceToEdited(clips, sourcePos);
    final snapEnabled = ref.read(snapPreferenceProvider);
    final overrideSnap = HardwareKeyboard.instance.isAltPressed;
    final zoomEdges = <Duration>[
      for (final r in ref
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
      setState(() => _selectedSliceIndex = null);
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
          setState(() => _selectedSliceIndex = null);
          return true;
        }
      }
      _flashPlayhead();
    }
    return true;
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

  /// Returns a sorted ascending list of edited-time snap candidates:
  /// cursor click events plus zoom-region start/end edges. Computed on
  /// demand per cut request — typical projects have a few hundred
  /// candidates and the cost is sub-millisecond.
  List<Duration> _buildSnapCandidates(List<ClipSlice> clips) {
    final candidates = <Duration>[];
    for (final t in _cursorRecording.eventIndex.clickTimes) {
      candidates.add(sourceToEdited(clips, t));
    }
    final regions = ref
        .read(editorProjectControllerProvider)
        .timeline
        .activeZoomRegions;
    for (final r in regions) {
      candidates.add(sourceToEdited(clips, r.startTime));
      candidates.add(sourceToEdited(clips, r.endTime));
    }
    candidates.sort();
    return candidates;
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
    final clips =
        ref.read(editorProjectControllerProvider).timeline.clips;
    if (clips.isEmpty) return;
    final pos =
        _smoothPlayhead?.position ?? _controller.value.position;
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
      try {
        _cursorRecording = await CursorRecording.loadFromFile(
          '${widget.videoPath}.cursor.json',
        );
      } catch (_) {
        _cursorRecording = CursorRecording();
      }
      _smoothPlayhead = SmoothPlayheadController(
        videoController: _controller,
        vsync: this,
      );

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
        if (hasNoZooms && hasClicks && _metadata != null) {
          final detected = const AutoZoomDetector().detect(
            cursor: _cursorRecording,
            videoSize: Size(
              _metadata!.widthPx.toDouble(),
              _metadata!.heightPx.toDouble(),
            ),
            videoDuration: _controller.value.duration,
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
      // Skip removed regions during playback. Wired alongside the
      // soft-trim tick so the two enforce-on-tick paths stay together.
      _controller.addListener(_onSkipTick);
      // Seed the hover anchor from the freshly-initialised controller
      // so hover-end-before-any-other-action restores to a meaningful
      // value rather than Duration.zero (which would jump to start).
      _hover = HoverScrubController(
        seekTo: _controller.seekTo,
        initialPosition: _controller.value.position,
      );
      _controller.addListener(_onHoverTrack);
      // Auto-play on load; fire-and-forget — the play state is tracked via
      // the controller's value listener, not by awaiting this future.
      unawaited(_controller.play());

      // Probe the recording's audio streams so the audio tab knows which
      // per-track controls to show. Non-fatal — failure leaves it empty.
      try {
        final probedForAudio = await ffmpegProbe(path: widget.videoPath);
        if (mounted) {
          ref.read(recordingAudioStreamsProvider.notifier).state =
              probedForAudio.audioStreams;
        }
      } catch (_) {/* leave empty */}
    } catch (e) {
      setState(() {
        _error = 'Failed to load video: $e';
      });
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
  void _onSkipTick() {
    if (!_isInitialized) return;
    final v = _controller.value;
    final clips = ref.read(editorProjectControllerProvider).timeline.clips;
    final target = shouldSeekOnTick(clips, v.position);
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
        v.position >= target) {
      _controller.pause();
    }
    _controller.seekTo(target);
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
      _smoothPlayhead?.removeListener(_onSpeedTick);
    }
    _smoothPlayhead?.dispose();
    _controller.dispose();
    _history?.dispose();
    _zoomDebugSnapshot.dispose();
    super.dispose();
  }

  void _handleUndo() => _history?.undo();
  void _handleRedo() => _history?.redo();

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
      videoBounds: _metadata == null
          ? null
          : Size(_metadata!.widthPx.toDouble(), _metadata!.heightPx.toDouble()),
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
          videoBounds: _metadata == null
              ? null
              : Size(
                  _metadata!.widthPx.toDouble(),
                  _metadata!.heightPx.toDouble(),
                ),
        ),
      );
    }
    _zoomPreviewOverride.value = null;
  }

  Size _videoSize() {
    final m = _metadata;
    if (m == null) return Size.zero;
    return Size(m.widthPx.toDouble(), m.heightPx.toDouble());
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
    );

    _projectController.addZoom(zoomRegion);
    _zoomPreviewOverride.value = null;
    setState(() {
      // Auto-select the new zoom so the inspector opens on it.
      _selectedZoomIndex = _project.zoomRegions.length - 1;
      _selectedSliceIndex = null;
    });
    _controller.seekTo(start);
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

  void _openFrameSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) {
          // Watch the controller so a sidecar load (or external
          // mutation) pushed into the notifier while this route is
          // mounted is reflected in the settings UI.
          return Consumer(builder: (context, ref, _) {
            final frame = ref.watch(editorProjectControllerProvider).windowFrame;
            return SettingsScreen(
              frame: frame,
              onChanged: ref
                  .read(editorProjectControllerProvider.notifier)
                  .setWindowFrame,
            );
          });
        },
      ),
    );
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
                  _bridgeAudioMix(ref.read(editorProjectControllerProvider)))
              .bitrateKbps,
          estimator: ExportEstimator(
            lastRealtimeMultiplier: persistedMultiplier ?? 0.7,
          ),
          onRevealLastExport: _lastExportPath == null
              ? null
              : () {
                  if (Platform.isMacOS) {
                    unawaited(Process.run('open', ['-R', _lastExportPath!])
                        .catchError((_) => ProcessResult(0, 1, '', '')));
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
      ExportDestination.file => FileSaver(),
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

    final progress = ValueNotifier<double?>(null);
    try {
      // Fire-and-forget: the dialog is dismissed via Navigator.pop below;
      // we don't need the returned Future<void>.
      unawaited(showDialog<void>(
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
      ));

      // Run the pipeline + deliver via the headless ExportController. The
      // pipeline is picked by format inside the injected closure; this widget
      // keeps all dialogs/snackbars/Navigator and maps the typed outcome to UI.
      final exportController = ExportController(
        runPipeline: ({required onProgress, required cancelToken}) {
          return settings!.format == ExportFormat.gif
              ? GifExportPipeline(
                  sourcePath: widget.videoPath,
                  outputPath: outPath!,
                  sourceMetadata: meta,
                  cursorRecording: cursorRec,
                  projectState: _project,
                  settings: settings,
                ).run(onProgress: onProgress, cancelToken: cancelToken)
              : ExportPipeline(
                  sourcePath: widget.videoPath,
                  outputPath: outPath!,
                  sourceMetadata: meta,
                  cursorRecording: cursorRec,
                  projectState: _project,
                  settings: settings,
                ).run(onProgress: onProgress, cancelToken: cancelToken);
          // N-slice export for both formats: per-slice trim/speed/fade come
          // from state.timeline.clips. The B-era top-level TrimSelection is
          // no longer plumbed into either pipeline.
        },
      );

      final outcome = await exportController.run(
        outputPath: outPath,
        handler: handler,
        onProgress: (p) => progress.value = p,
      );

      if (!mounted) return;
      Navigator.of(context).pop(); // close progress dialog

      switch (outcome) {
        case ExportSuccess(:final summary, :final result):
          // Persist settings minus the title (plan rule 5).
          await store.save(settings.copyWith(clearTitle: true));

          // Normalize the observed realtime multiplier to the estimator's
          // baseline (1080p @ 30fps) and persist it so the next dialog
          // open uses the actual hardware rate. Skipped for GIF because
          // its two-pass pipeline costs are dominated by palette work,
          // not the linear pixels-per-second model the estimator assumes.
          if (settings.format == ExportFormat.mp4 &&
              summary.realtimeMultiple > 0) {
            final outDims = settings.resolution.dimensionsFor(composedVideoSize);
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
                        unawaited(Process.run('open', ['-R', result.revealPath!])
                            .catchError((_) => ProcessResult(0, 1, '', '')));
                      }
                    },
                  )
                : null,
          );
        case ExportFailure(:final error):
          AppAlerts.error('Export failed: $error');
        case ExportCancelled():
          // No snackbar — user-initiated. (Today there's no cancel UI; this
          // arm is here for when a cancel button is wired to
          // exportController.cancel().)
          break;
      }
    } finally {
      progress.dispose();
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
  void _onHoverTrack() => _hover.track(_controller.value.position);

  void _seekToStart() => setState(() => _hover.seekToStart());

  void _seekToEnd() =>
      setState(() => _hover.seekToEnd(_controller.value.duration));

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
        final cmdOrCtrl = isMac
            ? event.logicalKey == LogicalKeyboardKey.meta ||
                  event.logicalKey == LogicalKeyboardKey.metaLeft ||
                  event.logicalKey == LogicalKeyboardKey.metaRight
            : event.logicalKey == LogicalKeyboardKey.control ||
                  event.logicalKey == LogicalKeyboardKey.controlLeft ||
                  event.logicalKey == LogicalKeyboardKey.controlRight;

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

        // Space: Play/Pause toggle
        if (event.logicalKey == LogicalKeyboardKey.space) {
          if (_controller.value.isPlaying) {
            _controller.pause();
          } else {
            _controller.play();
          }
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
                .setTimelineScale(
                  next,
                  anchorTime: _controller.value.position,
                ),
          ),
          child: Scaffold(
            backgroundColor: context.palette.appBackground,
            appBar: AppBar(
              title: const Text('Playback'),
              backgroundColor: context.palette.surfaceElevated,
              elevation: 0,
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Container(height: 1, color: context.palette.dividerSubtle),
              ),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
              actions: [
                // Secondary action — ghost style so the eye lands on the
                // CTA next to it. Returns to the recording screen for a
                // fresh take.
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.fiber_manual_record,
                    size: 16,
                    color: Colors.white70,
                  ),
                  label: const Text(
                    'Record another',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Primary CTA — filled indigo, matches the brand accent
                // used for selected zoom regions / active toggles. The
                // leading icon swaps for a rotating arc while an export
                // is in flight, and the button is disabled to block
                // re-entry (the _isExporting guard in _export covers it
                // anyway, but the visual cue matters).
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: TipAnchor(
                    tipId: TipId.editorExport,
                    child: ElevatedButton.icon(
                      onPressed: _isExporting ? null : _export,
                      icon: _isExporting
                          ? const CtaSpinner(size: 16)
                          : const Icon(Icons.file_download_outlined, size: 18),
                      label: Text(
                        _isExporting ? 'Exporting…' : 'Export',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.palette.accent,
                        foregroundColor: Colors.white,
                        // Keep the button looking active (not greyed out)
                        // while in the loading state — the spinner already
                        // says "busy", the disabled colour would just
                        // wash out the CTA.
                        disabledBackgroundColor: context.palette.accent,
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
            ),
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
                                color: context.palette.dividerSubtle),
                            CanvasToolbar(children: [
                              AspectRatioPicker(
                                current: project.outputAspect,
                                onChanged: (v) => ref
                                    .read(editorProjectControllerProvider.notifier)
                                    .setOutputAspect(v),
                              ),
                            ]),
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
                                child: ValueListenableBuilder<ZoomDebugSnapshot?>(
                                  valueListenable: _zoomDebugSnapshot,
                                  builder: (context, snap, _) {
                                    if (snap == null) {
                                      return const SizedBox.shrink();
                                    }
                                    return ZoomDebugReadoutPanel(
                                      cursor: snap.cursor,
                                      smoothedFocal: snap.smoothedFocal,
                                      activeZoom: snap.activeZoom,
                                      inFlight: snap.inFlight,
                                      focalVelocity: snap.focalVelocity,
                                      cursorVelocity: snap.cursorVelocity,
                                      videoSize: snap.videoSize,
                                      cursorSampleCount: snap.cursorSampleCount,
                                      position: snap.position,
                                      cursorXRange: snap.cursorXRange,
                                      cursorYRange: snap.cursorYRange,
                                      lastSnapReason: snap.lastSnapReason,
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
                      if (_isInitialized)
                        VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: context.palette.dividerSubtle),
                      if (_isInitialized)
                        InspectorPanel(
                          selection: _currentSelection(),
                          zoomRegions: project.zoomRegions,
                          clipDuration: _controller.value.duration,
                          canHideCursor: _metadata?.isPureSource == true &&
                              _cursorRecording.count > 0,
                          curveLibrary: _curveLibrary,
                          onZoomChanged: (i, next) {
                            _zoomPreviewOverride.value = null;
                            _projectController.updateZoomAt(i, next);
                          },
                          onZoomDeleted: (index) {
                            _projectController.removeZoomAt(index);
                            _setSelectedZoomIndex(null);
                          },
                          onSelectionCleared: () {
                            _zoomPreviewOverride.value = null;
                            setState(() {
                              _selectedZoomIndex = null;
                              _selectedSliceIndex = null;
                            });
                          },
                          onSliceRemoved: (removed) {
                            setState(() {
                              _selectedSliceIndex =
                                  decrementSelectionOnRemoval(
                                selected: _selectedSliceIndex,
                                removed: removed,
                              );
                            });
                          },
                          videoSize: _videoSize(),
                          onPlacementPreview: _onPlacementPreview,
                          onPlacementCommit: _onPlacementCommit,
                        ),
                    ],
                  ),
                ),
                Divider(
                    height: 1,
                    thickness: 1,
                    color: context.palette.dividerSubtle),
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
    // Scene-blur is handled OUTSIDE PlaybackCanvas by
    // [SceneBlurOverlay] (matches the playground's working pipeline:
    // captures the full output then smears uniformly, avoiding the
    // 1-frame edge-mismatch jitter the in-canvas pass had during
    // scrubs/knob drags). We disable PlaybackCanvas's internal scene
    // blur by passing 0 for both screen channels — its
    // `wantsScenePass` gate short-circuits in that case. The cursor
    // channel stays live because cursor accumulation runs in
    // PlaybackCanvas (no capture lag — it stamps from the recording).
    final project = ref.watch(editorProjectControllerProvider);
    final currentSlice = clipSliceAt(
      project.timeline.clips,
      _controller.value.position,
    );
    final playbackCanvas = PlaybackCanvas(
      controller: _controller,
      smoothPlayhead: _smoothPlayhead,
      frame: project.windowFrame,
      outputAspect: project.outputAspect,
      metadata: _metadata,
      cursorRecording: _cursorRecording,
      hideCursorOverlay: project.hideCursorOverlay,
      sliceHideCursor: currentSlice.hideCursor,
      sliceDisableSmoothMouse: currentSlice.disableSmoothMouse,
      cursorSize: project.cursorSize,
      cursorStyle: project.cursorStyle,
      cursorClickEffect: project.cursorClickEffect,
      showZoomDebug: _showZoomDebug,
      debugSnapshot: _zoomDebugSnapshot,
      zoomRegions: project.zoomRegions,
      screenAnimationConfig: project.screenAnimationConfig,
      cursorAnimationConfig: project.cursorAnimationConfig,
      motionBlur: project.motionBlur,
      cursorMovementBlur: project.cursorMovementBlur,
      screenMovementBlur: 0.0,
      screenZoomBlur: 0.0,
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
      accumulationExposureMs: 150.0,
      cursorShadow: project.cursorShadow,
      clickSpring: project.clickSpring,
      cursorDelay: project.cursorDelay,
      isHoverScrubbing: isHoverScrubbing,
      cursorPostProcess: project.cursorPostProcess,
      zoomPreviewOverride: _zoomPreviewOverride,
    );

    final videoSize = _controller.value.size;
    // The controller reports an empty size during the brief window
    // between initialize() and the first decoded frame. Return the
    // bare canvas in that case — SceneBlurOverlay mounts (with fresh
    // state) on the rebuild that delivers a real videoSize, which is
    // the desired reset semantics: its controllers start clean when
    // the actual recording lands.
    if (videoSize.isEmpty) return playbackCanvas;
    // Cubic response curve for scene-blur knobs. Slider UI stays
    // linear; the effective exposure scales with the slider value
    // cubed (normalized so the maximum is preserved). At slider 1%
    // the effective multiplier collapses by a factor of 10000, so
    // "wantsPass" flipping on at any non-zero slider position
    // produces a near-identity signal that's visually
    // indistinguishable from off. The bottom 30-40% of each slider
    // is effectively a soft on-ramp; the visible action happens in
    // the upper half. Cursor blur stays linear — it's path-stamped
    // and doesn't have the same gate-induced 0↔1% jump.
    final masterCurved =
        project.motionBlur * project.motionBlur * project.motionBlur / 0.25;
    final screenMovementCurved = project.screenMovementBlur *
        project.screenMovementBlur *
        project.screenMovementBlur;
    final screenZoomCurved =
        project.screenZoomBlur * project.screenZoomBlur * project.screenZoomBlur;
    return SceneBlurOverlay(
      controller: _controller,
      smoothPlayhead: _smoothPlayhead,
      cursorRecording: _cursorRecording,
      zoomRegions: project.zoomRegions,
      cursorAnimationConfig: project.cursorAnimationConfig,
      screenAnimationConfig: project.screenAnimationConfig,
      motionBlur: masterCurved,
      screenMovementBlur: screenMovementCurved,
      screenZoomBlur: screenZoomCurved,
      isHoverScrubbing: isHoverScrubbing,
      videoSize: videoSize,
      fps: _metadata?.fps ?? 60,
      cursorPostProcess: project.cursorPostProcess,
      child: playbackCanvas,
    );
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
        final pos = _hover.isHovering
            ? _hover.intendedPosition
            : (_smoothPlayhead?.position ?? _controller.value.position);
        final dur = _controller.value.duration;
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
                      onPressed: () => setState(
                          () => _cutModeActive = !_cutModeActive),
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
                  const SizedBox(width: 8),
                  const SnapTogglePill(),
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

    return Container(
      padding: const EdgeInsets.all(24),
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
          _buildTransportBar(),
          const SizedBox(height: 12),

          // Stacked timeline (time ruler + clip lane + zoom lane).
          AnimatedBuilder(
            animation: Listenable.merge([_controller, _smoothPlayhead]),
            builder: (context, _) {
              // The colored playhead and time labels stay parked at
              // the hover anchor (which is frozen while hovering)
              // even though the controller is being seeked to preview
              // the hover frame.
              final displayedPos = _hover.isHovering
                  ? _hover.intendedPosition
                  : (_smoothPlayhead?.position ?? _controller.value.position);
              // The timeline's x-axis is edited time: ruler width =
              // total edited duration, playhead = source mapped to
              // edited, scrub callbacks deliver edited and we convert
              // back to source before seeking the controller.
              final clipsForTimeline = ref
                  .watch(editorProjectControllerProvider)
                  .timeline
                  .clips;
              final editedDuration = clipsForTimeline.isEmpty
                  ? _controller.value.duration
                  : totalEditedDuration(clipsForTimeline);
              final editedPos = clipsForTimeline.isEmpty
                  ? displayedPos
                  : sourceToEdited(clipsForTimeline, displayedPos);
              return EditorTimeline(
                duration: editedDuration,
                position: editedPos,
                isPlaying: _controller.value.isPlaying,
                timelineScale:
                    ref.watch(editorProjectControllerProvider).timelineScale,
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
                  final clips = ref
                      .read(editorProjectControllerProvider)
                      .timeline
                      .clips;
                  final sourceNext = clips.isEmpty
                      ? editedNext
                      : seekFromEditedTime(clips, editedNext);
                  setState(() => _hover.seek(sourceNext));
                  _checkZoomMarkerClick(sourceNext);
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
                },
                onHoverEnd: () {
                  setState(() => _hover.hoverEnd());
                },
                zoomRegions: _project.zoomRegions,
                selectedZoomIndex: _selectedZoomIndex,
                onZoomSelected: (i) {
                  if (i != _selectedZoomIndex) {
                    _zoomPreviewOverride.value = null;
                  }
                  setState(() {
                    _selectedZoomIndex = i;
                    // Zoom and slice selections are mutually exclusive
                    // — selecting a zoom clears any slice selection.
                    if (i != null) _selectedSliceIndex = null;
                  });
                },
                onZoomChanged: (i, next) {
                  _zoomPreviewOverride.value = null;
                  _projectController.updateZoomAt(i, next);
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
                    }
                  });
                },
                onSliceTrimStartChanged: (idx, v) => ref
                    .read(editorProjectControllerProvider.notifier)
                    .setSliceTrimStart(idx, v),
                onSliceTrimEndChanged: (idx, v) => ref
                    .read(editorProjectControllerProvider.notifier)
                    .setSliceTrimEnd(idx, v),
                cutModeActive: _cutModeActive,
                onCutModeChanged: (v) =>
                    setState(() => _cutModeActive = v),
                playheadFlashOn: _playheadFlashOn,
                cursorClickTimes: _cursorRecording.eventIndex.clickTimes,
                onSnapped: _flashSnap,
                snapFlashTarget: _snapFlashTarget,
                // cursorXListenable stays unset — when cut mode is on,
                // EditorTimeline pipes its own overlay's cursor in. Off
                // mode falls back to a no-op notifier.
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

              // Frame settings button. Reads windowFrame through the
              // controller so the tint flips the moment the user picks
              // a non-None template — same source of truth as the
              // PlaybackCanvas's `frame` prop above.
              IconButton(
                onPressed: _openFrameSettings,
                icon: const Icon(Icons.settings),
                color: ref.watch(editorProjectControllerProvider).windowFrame.name !=
                        'None'
                    ? context.palette.accent
                    : Colors.white70,
                tooltip: 'Frame Settings',
              ),

              // Dev HUD toggle: shows the recorded cursor position
              // overlaid on the video so we can verify the zoom focal
              // is following it.
              IconButton(
                onPressed: () =>
                    setState(() => _showZoomDebug = !_showZoomDebug),
                icon: const Icon(Icons.gps_fixed),
                color: _showZoomDebug
                    ? context.palette.accent
                    : Colors.white38,
                tooltip: _showZoomDebug ? 'Hide cursor HUD' : 'Show cursor HUD',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
