import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:screen_recorder/effects/accumulation_cursor_painter.dart' show CursorBlurMode;
import 'package:screen_recorder/effects/motion_blur_tuning.dart';
import 'package:screen_recorder/models/trim_selection.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
import 'package:screen_recorder/rendering/spring_config.dart';
import 'package:screen_recorder/services/curve_library.dart';
import 'package:screen_recorder/services/destination_handlers.dart';
import 'package:screen_recorder/state/cursor_post_process.dart';
import 'package:screen_recorder/state/editor_project_state.dart';
import 'package:screen_recorder/state/editor_project_store.dart';
import 'package:screen_recorder/state/export_settings_store.dart';
import 'package:screen_recorder/state/export_telemetry_store.dart';
import 'package:screen_recorder/export/export_estimator.dart';
import 'package:screen_recorder/models/compression_bitrate.dart';
import 'package:screen_recorder/state/undo_redo_controller.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/ui/widgets/cta_spinner.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_panel.dart';
import 'package:screen_recorder/ui/widgets/inspector/timeline_selection.dart';
import 'package:screen_recorder/ui/widgets/transport/transport_buttons.dart';
import 'package:screen_recorder/ui/widgets/scene_blur_overlay.dart';
import 'package:screen_recorder/ui/widgets/zoom/playback_canvas.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_debug_painter.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/export_dialog.dart';
import 'package:screen_recorder/ui/screens/settings_screen.dart';
import 'package:screen_recorder/export/export_pipeline.dart';
import 'package:screen_recorder/export/gif_export_pipeline.dart';
import 'package:screen_recorder/export/ffmpeg_probe.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/recording_metadata.dart';

class PlaybackScreen extends StatefulWidget {
  final String videoPath;

  const PlaybackScreen({super.key, required this.videoPath});

  @override
  State<PlaybackScreen> createState() => _PlaybackScreenState();
}

class _PlaybackScreenState extends State<PlaybackScreen>
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
  TrimSelection? _trimSelection;
  late UndoRedoController<TrimSelection> _undoRedo;
  List<ZoomRegion> _zoomRegions = [];
  int? _selectedZoomIndex;
  // Whether the main clip bar is currently selected. Mutually
  // exclusive with [_selectedZoomIndex]: selecting one clears the
  // other. Drives the inspector's context-mode display.
  bool _isClipSelected = false;
  // Whether the synthetic cursor overlay is hidden in the preview.
  // Toggled from the inspector's "Hide cursor" control. Only meaningful
  // when the recording is pure source (cursor not baked into the MP4).
  bool _hideCursorOverlay = false;
  // Cursor visual settings — live-applied to the playback overlay and
  // forwarded to the export pipeline so the rendered video matches.
  double _cursorSize = 2.0;
  CursorStyle _cursorStyle = CursorStyle.modernDark;
  CursorClickEffect _cursorClickEffect = CursorClickEffect.ripple;
  // Animation tab — screen + cursor styles + motion blur amount.
  ScreenAnimationConfig _screenAnimationConfig =
      const ScreenAnimationConfig.preset(ScreenAnimationStyle.smooth);
  CursorAnimationConfig _cursorAnimationConfig =
      const CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
  double _motionBlur = 0;
  double _cursorMovementBlur = 1.0;
  double _screenMovementBlur = 1.0;
  double _screenZoomBlur = 1.0;
  // Live-tunable knobs for the cursor motion-blur path. Exposed in
  double _cursorShadow = 0.4;
  // Press-pulse spring. Default is snappy / critically damped; the
  // cursor tab's Springs section edits this in-place and persists via
  // EditorProjectState.
  ClickSpring _clickSpring = ClickSpring.snappy;
  // Cursor playback delay — shifts the cursor track's query time
  // backward by this much so the sprite visually arrives at UI
  // elements at the same moment they react in the recording (most
  // macOS apps redraw ~30–80 ms after a cursor event). Default 50 ms
  // is a reasonable universal value; live-tunable from the cursor
  // tab's Debug section and persisted on the project so the export
  // pipeline reads the same value.
  Duration _cursorDelay = const Duration(milliseconds: 50);
  // Per-project cursor post-processing — end-of-clip freeze, shake
  // removal, rapid-state-change debounce. Edited from the cursor tab's
  // Advanced section. Defaults to all filters off so existing projects
  // load with unchanged behaviour.
  CursorPostProcess _cursorPostProcess = CursorPostProcess.none;
  late FrameSettingsProvider _frameSettings;
  RecordingMetadata? _metadata;
  CursorRecording _cursorRecording = CursorRecording();
  // The user's intended position — the spot we return to when a
  // hover-preview ends. Updated continuously while the user is NOT
  // hover-scrubbing (so it tracks playback and committed seeks), and
  // frozen while [_isHovering] is true (so hover seeks don't
  // overwrite the anchor with previewed positions). Replaces the
  // earlier `_hoverFrozenPosition` capture-at-hover-start scheme,
  // which raced against the previous hover's restore seek not yet
  // applying — letting a re-entering hover capture the last preview
  // position as the "parked" target instead of the user's actual
  // stopped position.
  Duration _intendedPosition = Duration.zero;
  // True while a hover-scrub is in progress. The colored playhead and
  // time labels display [_intendedPosition] (frozen) while this is
  // set; PlaybackCanvas / SceneBlurOverlay receive it as
  // `isHoverScrubbing` so their stateful smoothers bypass.
  bool _isHovering = false;
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
    _undoRedo = UndoRedoController<TrimSelection>();
    _frameSettings = FrameSettingsProvider();
    _frameSettings.addListener(_onFrameSettingsChanged);
    _initializeVideo();
  }

  /// Compute the inspector's current timeline-selection input from
  /// the screen's selection state. Zoom selection wins if both are
  /// somehow set (only one can be set under normal flow because the
  /// tap handlers clear the other).
  TimelineSelection? _currentSelection() {
    if (_selectedZoomIndex != null) {
      return ZoomSelected(_selectedZoomIndex!);
    }
    if (_isClipSelected) return const ClipSelected();
    return null;
  }

  void _onFrameSettingsChanged() {
    setState(() {});
    _persistProject();
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
      final saved = await _projectStore.load();
      _zoomRegions = List.of(saved.zoomRegions);
      _screenAnimationConfig = saved.screenAnimationConfig;
      _cursorAnimationConfig = saved.cursorAnimationConfig;
      _cursorSize = saved.cursorSize;
      _cursorStyle = saved.cursorStyle;
      _cursorClickEffect = saved.cursorClickEffect;
      _hideCursorOverlay = saved.hideCursorOverlay;
      _motionBlur = saved.motionBlur;
      _cursorMovementBlur = saved.cursorMovementBlur;
      _screenMovementBlur = saved.screenMovementBlur;
      _screenZoomBlur = saved.screenZoomBlur;
      _cursorShadow = saved.cursorShadow;
      _clickSpring = saved.clickSpring;
      _cursorDelay = saved.cursorDelay;
      _cursorPostProcess = saved.cursorPostProcess;
      // Frame chrome (wallpaper, padding, corners, shadow, blur) is
      // also per-clip. Restore via setFrame BEFORE flipping the
      // _isInitialized flag so _persistProject won't fire on the
      // listener callback during init.
      _frameSettings.setFrame(saved.windowFrame);

      setState(() {
        _isInitialized = true;
        // Initialize trim selection to full duration
        _trimSelection = TrimSelection(
          start: Duration.zero,
          end: _controller.value.duration,
          videoDuration: _controller.value.duration,
        );
        // Push initial state to undo/redo controller
        _undoRedo.push(_trimSelection!);
      });
      // Auto-pause when playback reaches the trim end. Wired after
      // _isInitialized + _trimSelection are set so the listener never
      // sees a half-initialized state.
      _controller.addListener(_enforceTrimBounds);
      // Seed [_intendedPosition] from the freshly-initialised controller
      // so hover-end-before-any-other-action restores to a meaningful
      // value rather than Duration.zero (which would jump to start).
      _intendedPosition = _controller.value.position;
      _controller.addListener(_trackIntendedPosition);
      // Auto-play on load
      _controller.play();
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
  void _enforceTrimBounds() {
    final trim = _trimSelection;
    if (trim == null) return;
    final value = _controller.value;
    if (!value.isPlaying) return;
    if (value.position >= trim.end) {
      _controller.pause();
      _controller.seekTo(trim.end);
    }
  }

  /// Snapshot of the current persistable editor state.
  EditorProjectState _captureProjectState() => EditorProjectState(
    zoomRegions: List.unmodifiable(_zoomRegions),
    screenAnimationConfig: _screenAnimationConfig,
    cursorAnimationConfig: _cursorAnimationConfig,
    cursorSize: _cursorSize,
    cursorStyle: _cursorStyle,
    cursorClickEffect: _cursorClickEffect,
    hideCursorOverlay: _hideCursorOverlay,
    motionBlur: _motionBlur,
    cursorMovementBlur: _cursorMovementBlur,
    screenMovementBlur: _screenMovementBlur,
    screenZoomBlur: _screenZoomBlur,
    cursorShadow: _cursorShadow,
    clickSpring: _clickSpring,
    cursorDelay: _cursorDelay,
    windowFrame: _frameSettings.currentFrame,
    cursorPostProcess: _cursorPostProcess,
  );

  /// Schedule a debounced save so a slider drag doesn't hammer the
  /// disk on every tick. Call after any setState that mutates a
  /// tracked field.
  void _persistProject() {
    if (!_isInitialized) return; // Don't overwrite on the load pass.
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      _projectStore.save(_captureProjectState());
    });
  }

  @override
  void dispose() {
    // Flush any pending debounced save before tearing down so the
    // user doesn't lose the last change they made before navigating
    // away. Fire-and-forget — atomic write + the store's mutation
    // queue mean a partially-written file is impossible.
    _saveDebounce?.cancel();
    if (_isInitialized) {
      _projectStore.save(_captureProjectState());
      _controller.removeListener(_enforceTrimBounds);
      _controller.removeListener(_trackIntendedPosition);
    }
    _smoothPlayhead?.dispose();
    _controller.dispose();
    _frameSettings.removeListener(_onFrameSettingsChanged);
    _frameSettings.dispose();
    _zoomDebugSnapshot.dispose();
    super.dispose();
  }

  void _handleUndo() {
    if (_undoRedo.canUndo) {
      final previousState = _undoRedo.undo();
      if (previousState != null) {
        setState(() {
          _trimSelection = previousState;
        });
      }
    }
  }

  void _handleRedo() {
    if (_undoRedo.canRedo) {
      final nextState = _undoRedo.redo();
      if (nextState != null) {
        setState(() {
          _trimSelection = nextState;
        });
      }
    }
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

    setState(() {
      _zoomRegions = [..._zoomRegions, zoomRegion];
      // Auto-select the new zoom so the inspector opens on it.
      _selectedZoomIndex = _zoomRegions.length - 1;
      _isClipSelected = false;
    });
    _persistProject();
    _controller.seekTo(start);
  }

  void _checkZoomMarkerClick(Duration position) {
    // Find zoom region near clicked position (within 0.5 seconds).
    const tolerance = Duration(milliseconds: 500);
    int? newIndex;
    for (var i = 0; i < _zoomRegions.length; i++) {
      if ((position - _zoomRegions[i].startTime).abs() < tolerance) {
        newIndex = i;
        break;
      }
    }
    // Only setState when the selection actually changes — otherwise dragging
    // the playhead causes a setState every tick which rebuilds the whole
    // video panel (gradient backdrop + 80px-blur frame shadow + ClipRRect +
    // Transform), making the seek visibly heavy.
    if (newIndex != _selectedZoomIndex) {
      setState(() => _selectedZoomIndex = newIndex);
    }
  }

  void _openFrameSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SettingsScreen(settingsProvider: _frameSettings),
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
          sourceVideoSize: sourceVideoSize,
          videoDuration: videoDuration,
          audioBitrateKbps: probed.audioBitrateKbps,
          estimator: ExportEstimator(
            lastRealtimeMultiplier: persistedMultiplier ?? 0.7,
          ),
          onRevealLastExport: _lastExportPath == null
              ? null
              : () => Process.run('open', ['-R', _lastExportPath!]),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Couldn\'t prepare export: $e'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (settings == null || !mounted) return;

    // ── GIF >60s gate ──────────────────────────────────────────────────
    if (settings.format == ExportFormat.gif && videoDuration.inSeconds > 60) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'GIF export is limited to clips of 60 seconds or less. '
            'Try MP4 instead.',
          ),
          backgroundColor: Colors.orange,
        ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Couldn\'t pick a save location: $e'),
          backgroundColor: Colors.red,
        ),
      );
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
      );

      try {
        final summary = settings.format == ExportFormat.gif
            ? await GifExportPipeline(
                sourcePath: widget.videoPath,
                outputPath: outPath,
                sourceMetadata: meta,
                cursorRecording: cursorRec,
                projectState: _captureProjectState(),
                settings: settings,
              ).run(onProgress: (p) => progress.value = p)
            : await ExportPipeline(
                sourcePath: widget.videoPath,
                outputPath: outPath,
                sourceMetadata: meta,
                cursorRecording: cursorRec,
                projectState: _captureProjectState(),
                settings: settings,
              ).run(onProgress: (p) => progress.value = p);

        if (!mounted) return;
        Navigator.of(context).pop(); // close progress dialog

        // Persist settings minus the title (plan rule 5).
        await store.save(settings.copyWith(clearTitle: true));

        // Normalize the observed realtime multiplier to the estimator's
        // baseline (1080p @ 30fps) and persist it so the next dialog
        // open uses the actual hardware rate. Skipped for GIF because
        // its two-pass pipeline costs are dominated by palette work,
        // not the linear pixels-per-second model the estimator assumes.
        if (settings.format == ExportFormat.mp4 &&
            summary.realtimeMultiple > 0) {
          final outDims = settings.resolution.dimensionsFor(sourceVideoSize);
          final outArea = outDims.width * outDims.height;
          final fpsScale = settings.frameRate / kBaselineFrameRate;
          final areaScale = outArea / kBaselineAreaPixels;
          final normalized = summary.realtimeMultiple * fpsScale * areaScale;
          unawaited(telemetryStore.saveRealtimeMultiplier(normalized));
        }

        final result = await handler.deliver(outPath);
        if (!mounted) return;

        // Record the export path so the reveal-in-Finder button lights up
        // the next time the dialog is opened.
        setState(() => _lastExportPath = outPath);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: const Color(0xFF4CAF50),
            action: result.revealPath != null
                ? SnackBarAction(
                    label: 'Show in Finder',
                    onPressed: () {
                      // macOS-only: reveal in Finder. No-op on other platforms.
                      if (Platform.isMacOS) {
                        Process.run('open', ['-R', result.revealPath!]);
                      }
                    },
                  )
                : null,
          ),
        );
      } catch (e) {
        if (!mounted) return;
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
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
  // value changes AND we're not in the middle of a hover-scrub. Hover
  // seeks are excluded so [_intendedPosition] freezes at the anchor
  // we want to restore to when the hover ends.
  void _trackIntendedPosition() {
    if (_isHovering) return;
    _intendedPosition = _controller.value.position;
  }

  void _seekToStart() {
    setState(() {
      _isHovering = false;
      _intendedPosition = Duration.zero;
    });
    _controller.seekTo(Duration.zero);
  }

  void _seekToEnd() {
    setState(() {
      _isHovering = false;
    });
    final dur = _controller.value.duration;
    if (dur > Duration.zero) {
      // 1ms back from the end so the player doesn't auto-rewind on
      // the next tick (some VideoPlayer backends snap a position
      // exactly at duration to 0).
      _controller.seekTo(dur - const Duration(milliseconds: 1));
    }
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
          if (_undoRedo.canUndo) {
            _handleUndo();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // Redo: Cmd+Shift+Z (Mac) or Ctrl+Shift+Z (Windows/Linux)
        if (cmdOrCtrl &&
            event.logicalKey == LogicalKeyboardKey.keyZ &&
            HardwareKeyboard.instance.isShiftPressed) {
          if (_undoRedo.canRedo) {
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
      child: Scaffold(
        backgroundColor: const Color(0xFF1E1E2E),
        appBar: AppBar(
          title: const Text('Playback'),
          backgroundColor: const Color(0xFF2B2B3D),
          elevation: 0,
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
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white,
                  // Keep the button looking active (not greyed out)
                  // while in the loading state — the spinner already
                  // says "busy", the disabled colour would just
                  // wash out the CTA.
                  disabledBackgroundColor: const Color(0xFF6C63FF),
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
                    child: Stack(
                      children: [
                        Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0xFF181826),
                                Color(0xFF0E0E18),
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
                  if (_isInitialized)
                    InspectorPanel(
                      frameSettings: _frameSettings,
                      selection: _currentSelection(),
                      zoomRegions: _zoomRegions,
                      clipDuration: _controller.value.duration,
                      hideCursor: _hideCursorOverlay,
                      canHideCursor:
                          _metadata?.isPureSource == true &&
                          _cursorRecording.count > 0,
                      onHideCursorChanged: (v) {
                        setState(() => _hideCursorOverlay = v);
                        _persistProject();
                      },
                      cursorSize: _cursorSize,
                      cursorStyle: _cursorStyle,
                      cursorClickEffect: _cursorClickEffect,
                      cursorShadow: _cursorShadow,
                      onCursorSizeChanged: (v) {
                        setState(() => _cursorSize = v);
                        _persistProject();
                      },
                      onCursorStyleChanged: (s) {
                        setState(() => _cursorStyle = s);
                        _persistProject();
                      },
                      onCursorClickEffectChanged: (e) {
                        setState(() => _cursorClickEffect = e);
                        _persistProject();
                      },
                      onCursorShadowChanged: (v) {
                        setState(() => _cursorShadow = v);
                        _persistProject();
                      },
                      screenAnimationConfig: _screenAnimationConfig,
                      cursorAnimationConfig: _cursorAnimationConfig,
                      motionBlur: _motionBlur,
                      cursorMovementBlur: _cursorMovementBlur,
                      screenMovementBlur: _screenMovementBlur,
                      screenZoomBlur: _screenZoomBlur,
                      onScreenAnimationConfigChanged: (c) {
                        setState(() => _screenAnimationConfig = c);
                        _persistProject();
                      },
                      onCursorAnimationConfigChanged: (c) {
                        setState(() => _cursorAnimationConfig = c);
                        _persistProject();
                      },
                      onMotionBlurChanged: (v) {
                        setState(() => _motionBlur = v);
                        _persistProject();
                      },
                      onCursorMovementBlurChanged: (v) {
                        setState(() => _cursorMovementBlur = v);
                        _persistProject();
                      },
                      onScreenMovementBlurChanged: (v) {
                        setState(() => _screenMovementBlur = v);
                        _persistProject();
                      },
                      onScreenZoomBlurChanged: (v) {
                        setState(() => _screenZoomBlur = v);
                        _persistProject();
                      },
                      clickSpring: _clickSpring,
                      onClickSpringChanged: (s) {
                        setState(() => _clickSpring = s);
                        _persistProject();
                      },
                      cursorDelay: _cursorDelay,
                      onCursorDelayChanged: (d) {
                        setState(() => _cursorDelay = d);
                        _persistProject();
                      },
                      cursorPostProcess: _cursorPostProcess,
                      onCursorPostProcessChanged: (cfg) {
                        setState(() => _cursorPostProcess = cfg);
                        _persistProject();
                      },
                      curveLibrary: _curveLibrary,
                      onZoomChanged: (index, next) {
                        setState(() => _zoomRegions[index] = next);
                        _persistProject();
                      },
                      onZoomDeleted: (index) {
                        setState(() {
                          _zoomRegions.removeAt(index);
                          _selectedZoomIndex = null;
                        });
                        _persistProject();
                      },
                      onSelectionCleared: () => setState(() {
                        _selectedZoomIndex = null;
                        _isClipSelected = false;
                      }),
                    ),
                ],
              ),
            ),
            _buildControls(),
          ],
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
      return const CircularProgressIndicator(color: Color(0xFF6C63FF));
    }

    // _isHovering is set on the first hover-seek and cleared on
    // hover-end / committed seek. It's a precise "we're scrubbing,
    // not playing" signal — the canvas uses it to bypass stateful
    // smoothers (EMA velocity, focal tween) so forward and backward
    // hover render the same frame at the same timestamp.
    final isHoverScrubbing = _isHovering;
    // Scene-blur is handled OUTSIDE PlaybackCanvas by
    // [SceneBlurOverlay] (matches the playground's working pipeline:
    // captures the full output then smears uniformly, avoiding the
    // 1-frame edge-mismatch jitter the in-canvas pass had during
    // scrubs/knob drags). We disable PlaybackCanvas's internal scene
    // blur by passing 0 for both screen channels — its
    // `wantsScenePass` gate short-circuits in that case. The cursor
    // channel stays live because cursor accumulation runs in
    // PlaybackCanvas (no capture lag — it stamps from the recording).
    final playbackCanvas = PlaybackCanvas(
      controller: _controller,
      smoothPlayhead: _smoothPlayhead,
      frameSettings: _frameSettings,
      metadata: _metadata,
      cursorRecording: _cursorRecording,
      hideCursorOverlay: _hideCursorOverlay,
      cursorSize: _cursorSize,
      cursorStyle: _cursorStyle,
      cursorClickEffect: _cursorClickEffect,
      showZoomDebug: _showZoomDebug,
      debugSnapshot: _zoomDebugSnapshot,
      zoomRegions: _zoomRegions,
      screenAnimationConfig: _screenAnimationConfig,
      cursorAnimationConfig: _cursorAnimationConfig,
      motionBlur: _motionBlur,
      cursorMovementBlur: _cursorMovementBlur,
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
      cursorShadow: _cursorShadow,
      clickSpring: _clickSpring,
      cursorDelay: _cursorDelay,
      isHoverScrubbing: isHoverScrubbing,
      cursorPostProcess: _cursorPostProcess,
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
    final masterCurved = _motionBlur * _motionBlur * _motionBlur / 0.25;
    final screenMovementCurved =
        _screenMovementBlur * _screenMovementBlur * _screenMovementBlur;
    final screenZoomCurved =
        _screenZoomBlur * _screenZoomBlur * _screenZoomBlur;
    return SceneBlurOverlay(
      controller: _controller,
      smoothPlayhead: _smoothPlayhead,
      cursorRecording: _cursorRecording,
      zoomRegions: _zoomRegions,
      cursorAnimationConfig: _cursorAnimationConfig,
      screenAnimationConfig: _screenAnimationConfig,
      motionBlur: masterCurved,
      screenMovementBlur: screenMovementCurved,
      screenZoomBlur: screenZoomCurved,
      isHoverScrubbing: isHoverScrubbing,
      videoSize: videoSize,
      fps: _metadata?.fps ?? 60,
      cursorPostProcess: _cursorPostProcess,
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
        final pos = _isHovering
            ? _intendedPosition
            : (_smoothPlayhead?.position ?? _controller.value.position);
        final dur = _controller.value.duration;
        final isPlaying = _controller.value.isPlaying;
        return Row(
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
      decoration: const BoxDecoration(
        color: Color(0xFF2B2B3D),
        boxShadow: [
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
              // [_intendedPosition] (which is frozen while hovering)
              // even though the controller is being seeked to preview
              // the hover frame.
              final displayedPos = _isHovering
                  ? _intendedPosition
                  : (_smoothPlayhead?.position ?? _controller.value.position);
              return EditorTimeline(
                duration: _controller.value.duration,
                position: displayedPos,
                isPlaying: _controller.value.isPlaying,
                onSeek: (next) {
                  // Committed seek: clear hover state and adopt the
                  // click target as the new intended position. The
                  // listener also picks this up after the seek lands,
                  // but we set it explicitly to avoid even a one-frame
                  // gap where _intendedPosition is still the old
                  // pre-hover value.
                  setState(() {
                    _isHovering = false;
                    _intendedPosition = next;
                  });
                  _controller.seekTo(next);
                  _checkZoomMarkerClick(next);
                },
                onHoverSeek: (next) {
                  // Mark hover active so the listener stops updating
                  // [_intendedPosition]. The anchor we'll restore to on
                  // hover-end is whatever the listener last wrote — i.e.
                  // the user's actual stopped position (the live
                  // playback position if they were playing, or the
                  // paused position otherwise). Crucially we do NOT
                  // sample `_controller.value.position` here, which
                  // could still be the previous hover's preview target
                  // if its restore-seek hadn't applied yet.
                  if (!_isHovering) {
                    setState(() => _isHovering = true);
                  }
                  _controller.seekTo(next);
                },
                onHoverEnd: () {
                  if (_isHovering) {
                    _controller.seekTo(_intendedPosition);
                    setState(() => _isHovering = false);
                  }
                },
                zoomRegions: _zoomRegions,
                selectedZoomIndex: _selectedZoomIndex,
                onZoomSelected: (i) {
                  setState(() {
                    _selectedZoomIndex = i;
                    // Zoom and clip selections are mutually exclusive
                    // — selecting a zoom clears any clip selection.
                    if (i != null) _isClipSelected = false;
                  });
                },
                clipSelected: _isClipSelected,
                onClipSelected: (selected) {
                  setState(() {
                    _isClipSelected = selected;
                    if (selected) _selectedZoomIndex = null;
                  });
                },
                onZoomChanged: (index, next) {
                  setState(() {
                    final list = List<ZoomRegion>.from(_zoomRegions);
                    list[index] = next;
                    _zoomRegions = list;
                  });
                },
                onZoomDeleted: (index) {
                  setState(() {
                    final list = List<ZoomRegion>.from(_zoomRegions)
                      ..removeAt(index);
                    _zoomRegions = list;
                    if (_selectedZoomIndex == index) {
                      _selectedZoomIndex = null;
                    } else if (_selectedZoomIndex != null &&
                        _selectedZoomIndex! > index) {
                      _selectedZoomIndex = _selectedZoomIndex! - 1;
                    }
                  });
                },
                onZoomAdded: _addZoomAt,
                trimSelection: _trimSelection,
                onTrimChanged: (next) {
                  setState(() => _trimSelection = next);
                },
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
                onPressed: _undoRedo.canUndo ? _handleUndo : null,
                icon: const Icon(Icons.undo),
                tooltip: 'Undo (Cmd+Z)',
                color: const Color(0xFF6C63FF),
                disabledColor: Colors.white24,
              ),

              // Redo button
              IconButton(
                onPressed: _undoRedo.canRedo ? _handleRedo : null,
                icon: const Icon(Icons.redo),
                tooltip: 'Redo (Cmd+Shift+Z)',
                color: const Color(0xFF6C63FF),
                disabledColor: Colors.white24,
              ),

              // Frame settings button
              IconButton(
                onPressed: _openFrameSettings,
                icon: const Icon(Icons.settings),
                color: _frameSettings.currentFrame.name != 'None'
                    ? const Color(0xFF6C63FF)
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
                    ? const Color(0xFF6C63FF)
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
