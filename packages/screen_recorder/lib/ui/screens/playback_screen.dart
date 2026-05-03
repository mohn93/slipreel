import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:screen_recorder/models/trim_selection.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
import 'package:screen_recorder/services/curve_library.dart';
import 'package:screen_recorder/services/destination_handlers.dart';
import 'package:screen_recorder/state/editor_project_state.dart';
import 'package:screen_recorder/state/editor_project_store.dart';
import 'package:screen_recorder/state/export_settings_store.dart';
import 'package:screen_recorder/state/undo_redo_controller.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_panel.dart';
import 'package:screen_recorder/ui/widgets/inspector/timeline_selection.dart';
import 'package:screen_recorder/ui/widgets/transport/transport_buttons.dart';
import 'package:screen_recorder/ui/widgets/zoom/playback_canvas.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/export_dialog.dart';
import 'package:screen_recorder/ui/screens/settings_screen.dart';
import 'package:screen_recorder/export/export_pipeline.dart';
import 'package:screen_recorder/export/gif_export_pipeline.dart';
import 'package:screen_recorder/export/ffmpeg_probe.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/recording_metadata.dart';

class PlaybackScreen extends StatefulWidget {
  final String videoPath;

  const PlaybackScreen({
    super.key,
    required this.videoPath,
  });

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
  double _cursorSize = 1.0;
  CursorStyle _cursorStyle = CursorStyle.modernDark;
  CursorClickEffect _cursorClickEffect = CursorClickEffect.ripple;
  // Animation tab — screen + cursor styles + motion blur amount.
  // motionBlur is captured but not yet rendered.
  ScreenAnimationConfig _screenAnimationConfig =
      const ScreenAnimationConfig.preset(ScreenAnimationStyle.smooth);
  CursorAnimationConfig _cursorAnimationConfig =
      const CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
  double _motionBlur = 0;
  late FrameSettingsProvider _frameSettings;
  RecordingMetadata? _metadata;
  CursorRecording _cursorRecording = CursorRecording();
  // Where playback was parked when a hover-scrub began. While this is
  // non-null the timeline's real (colored) playhead and the time labels
  // display this fixed value, even though the controller is being live-
  // seeked to follow the cursor for frame preview. Restored on hover end.
  Duration? _hoverFrozenPosition;
  // Dev HUD: when on, draws a marker at the recorded cursor's video-pixel
  // position so we can visually confirm the zoom focal is tracking it.
  bool _showZoomDebug = false;
  // Persistence for user-saved curves shown in the curve editor's
  // Library row. One instance per playback screen so saves survive
  // animation-tab rebuilds.
  final FileCurveLibrary _curveLibrary = FileCurveLibrary();
  // Per-recording editor settings (zoom regions, animation configs,
  // cursor visuals, etc.) — saved to a `<videoPath>.editor.json`
  // sidecar so the user's edits survive across app sessions.
  late final EditorProjectStore _projectStore =
      EditorProjectStore(videoPath: widget.videoPath);
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
            '${widget.videoPath}.cursor.json');
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
      // Auto-play on load
      _controller.play();
    } catch (e) {
      setState(() {
        _error = 'Failed to load video: $e';
      });
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
        windowFrame: _frameSettings.currentFrame,
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
    }
    _smoothPlayhead?.dispose();
    _controller.dispose();
    _frameSettings.removeListener(_onFrameSettingsChanged);
    _frameSettings.dispose();
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
        builder: (context) => SettingsScreen(
          settingsProvider: _frameSettings,
        ),
      ),
    );
  }

  Future<void> _export() async {
    // ── Phase 1: pre-dialog setup (probe + dialog) ─────────────────────
    // Any exception here (bad codec, missing metadata, probe failure)
    // shows a snackbar rather than dying silently.
    final ExportSettings? settings;
    final RecordingMetadata meta;
    final Duration videoDuration;
    final ExportSettingsStore store;

    try {
      store = await ExportSettingsStore.resolveDefault();
      final defaults = await store.load();

      if (!mounted) return;

      // Load source metadata — needed for dialog (resolution capping,
      // sub-label) and for the pipeline.
      meta = await RecordingMetadata.loadForVideo(widget.videoPath);
      final sourceVideoSize =
          Size(meta.widthPx.toDouble(), meta.heightPx.toDouble());

      // Probe the video to get the authoritative duration.
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
          onRevealLastExport: _lastExportPath == null
              ? null
              : () => Process.run('open', ['-R', _lastExportPath!]),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Couldn\'t prepare export: $e'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    if (settings == null || !mounted) return;

    // ── GIF >60s gate ──────────────────────────────────────────────────
    if (settings.format == ExportFormat.gif &&
        videoDuration.inSeconds > 60) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'GIF export is limited to clips of 60 seconds or less. '
          'Try MP4 instead.',
        ),
        backgroundColor: Colors.orange,
      ));
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Couldn\'t pick a save location: $e'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    if (outPath == null || !mounted) return;

    // ── Phase 3: encode ────────────────────────────────────────────────
    // Load cursor sidecar (best-effort).
    final cursorRec = await CursorRecording.loadFromFile(
            '${widget.videoPath}.cursor.json')
        .catchError((_) => CursorRecording());

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
        if (settings.format == ExportFormat.gif) {
          final pipeline = GifExportPipeline(
            sourcePath: widget.videoPath,
            outputPath: outPath,
            sourceMetadata: meta,
            cursorRecording: cursorRec,
            projectState: _captureProjectState(),
            settings: settings,
          );
          await pipeline.run(onProgress: (p) => progress.value = p);
        } else {
          final pipeline = ExportPipeline(
            sourcePath: widget.videoPath,
            outputPath: outPath,
            sourceMetadata: meta,
            cursorRecording: cursorRec,
            projectState: _captureProjectState(),
            settings: settings,
          );
          await pipeline.run(onProgress: (p) => progress.value = p);
        }

        if (!mounted) return;
        Navigator.of(context).pop(); // close progress dialog

        // Persist settings minus the title (plan rule 5).
        await store.save(settings.copyWith(clearTitle: true));

        final result = await handler.deliver(outPath);
        if (!mounted) return;

        // Record the export path so the reveal-in-Finder button lights up
        // the next time the dialog is opened.
        setState(() => _lastExportPath = outPath);

        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
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
        ));
      } catch (e) {
        if (!mounted) return;
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Export failed: $e'),
          backgroundColor: Colors.red,
        ));
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

  void _seekToStart() {
    if (_hoverFrozenPosition != null) {
      setState(() => _hoverFrozenPosition = null);
    }
    _controller.seekTo(Duration.zero);
  }

  void _seekToEnd() {
    if (_hoverFrozenPosition != null) {
      setState(() => _hoverFrozenPosition = null);
    }
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
    final hundredths =
        ((d.inMilliseconds % 1000) ~/ 10).toString().padLeft(2, '0');
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
        final cmdOrCtrl = isMac ? event.logicalKey == LogicalKeyboardKey.meta || event.logicalKey == LogicalKeyboardKey.metaLeft || event.logicalKey == LogicalKeyboardKey.metaRight
                                : event.logicalKey == LogicalKeyboardKey.control || event.logicalKey == LogicalKeyboardKey.controlLeft || event.logicalKey == LogicalKeyboardKey.controlRight;

        // Undo: Cmd+Z (Mac) or Ctrl+Z (Windows/Linux)
        if (cmdOrCtrl && event.logicalKey == LogicalKeyboardKey.keyZ && !HardwareKeyboard.instance.isShiftPressed) {
          if (_undoRedo.canUndo) {
            _handleUndo();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // Redo: Cmd+Shift+Z (Mac) or Ctrl+Shift+Z (Windows/Linux)
        if (cmdOrCtrl && event.logicalKey == LogicalKeyboardKey.keyZ && HardwareKeyboard.instance.isShiftPressed) {
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
        if (cmdOrCtrl &&
            event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _seekToStart();
          return KeyEventResult.handled;
        }
        if (cmdOrCtrl &&
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
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
        ),
        body: Column(
          children: [
            // Preview backdrop on the left, inspector panel on the right.
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0xFF181826),
                            Color(0xFF0E0E18)
                          ],
                        ),
                      ),
                      alignment: Alignment.center,
                      child: _buildVideoPlayer(),
                    ),
                  ),
                  if (_isInitialized)
                    InspectorPanel(
                      frameSettings: _frameSettings,
                      selection: _currentSelection(),
                      zoomRegions: _zoomRegions,
                      clipDuration: _controller.value.duration,
                      hideCursor: _hideCursorOverlay,
                      canHideCursor: _metadata?.isPureSource == true &&
                          _cursorRecording.count > 0,
                      onHideCursorChanged: (v) {
                        setState(() => _hideCursorOverlay = v);
                        _persistProject();
                      },
                      cursorSize: _cursorSize,
                      cursorStyle: _cursorStyle,
                      cursorClickEffect: _cursorClickEffect,
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
                      screenAnimationConfig: _screenAnimationConfig,
                      cursorAnimationConfig: _cursorAnimationConfig,
                      motionBlur: _motionBlur,
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
          const Icon(
            Icons.error_outline,
            size: 64,
            color: Colors.red,
          ),
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
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    if (!_isInitialized) {
      return const CircularProgressIndicator(
        color: Color(0xFF6C63FF),
      );
    }

    return PlaybackCanvas(
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
      zoomRegions: _zoomRegions,
      screenAnimationConfig: _screenAnimationConfig,
      cursorAnimationConfig: _cursorAnimationConfig,
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
        final pos = _hoverFrozenPosition ??
            (_smoothPlayhead?.position ?? _controller.value.position);
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
            animation:
                Listenable.merge([_controller, _smoothPlayhead]),
            builder: (context, _) {
              // The colored playhead and time labels stay parked at
              // _hoverFrozenPosition (when set) even while the controller
              // is being seeked to preview the hover frame.
              final displayedPos = _hoverFrozenPosition ??
                  (_smoothPlayhead?.position ?? _controller.value.position);
              return EditorTimeline(
                duration: _controller.value.duration,
                position: displayedPos,
                isPlaying: _controller.value.isPlaying,
                onSeek: (next) {
                  // Committed seek: clear any hover freeze first so the
                  // colored playhead lands at the click target instead of
                  // restoring to the parked position when hover ends.
                  if (_hoverFrozenPosition != null) {
                    setState(() => _hoverFrozenPosition = null);
                  }
                  _controller.seekTo(next);
                  _checkZoomMarkerClick(next);
                },
                onHoverSeek: (next) {
                  // Capture the parked position the first time hover
                  // fires so the colored playhead and time labels can
                  // stay put while we live-seek the controller for frame
                  // preview.
                  if (_hoverFrozenPosition == null) {
                    setState(() => _hoverFrozenPosition =
                        _controller.value.position);
                  }
                  _controller.seekTo(next);
                },
                onHoverEnd: () {
                  final parked = _hoverFrozenPosition;
                  if (parked != null) {
                    _controller.seekTo(parked);
                    setState(() => _hoverFrozenPosition = null);
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
                tooltip:
                    _showZoomDebug ? 'Hide cursor HUD' : 'Show cursor HUD',
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Record Another + Export
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Record Another button
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.fiber_manual_record),
                label: const Text('Record Another'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                ),
              ),

              const SizedBox(width: 16),

              // Export button
              ElevatedButton.icon(
                onPressed: _export,
                icon: const Icon(Icons.file_download),
                label: const Text('Export'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
