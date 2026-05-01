import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:screen_recorder/models/trim_selection.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/models/export_preset.dart';
import 'package:screen_recorder/effects/zoom_transformer.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';
import 'package:screen_recorder/rendering/frame_painter.dart';
import 'package:screen_recorder/state/undo_redo_controller.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart';
import 'package:screen_recorder/ui/widgets/timeline/smooth_playhead_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_panel.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_focal_controller.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_selector.dart';
import 'package:screen_recorder/ui/widgets/export_dialog.dart';
import 'package:screen_recorder/ui/screens/settings_screen.dart';
import 'package:screen_recorder/export/export_pipeline.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/models/recording_metadata.dart';
import 'package:screen_recorder/ui/widgets/cursor_overlay_painter.dart';

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
  TrimSelection? _trimSelection;
  late UndoRedoController<TrimSelection> _undoRedo;
  List<ZoomRegion> _zoomRegions = [];
  bool _isSelectingZoom = false;
  final _zoomTransformer = ZoomTransformer();
  int? _selectedZoomIndex;
  late FrameSettingsProvider _frameSettings;
  RecordingMetadata? _metadata;
  CursorRecording _cursorRecording = CursorRecording();
  // Where playback was parked when a hover-scrub began. While this is
  // non-null the timeline's real (colored) playhead and the time labels
  // display this fixed value, even though the controller is being live-
  // seeked to follow the cursor for frame preview. Restored on hover end.
  Duration? _hoverFrozenPosition;
  // Cursor-driven zoom focal smoothing. State (active-zoom tracking,
  // last smoothed offset) lives in the controller so it can be unit-
  // tested without a widget tree.
  final ZoomFocalController _zoomFocalController = ZoomFocalController();
  // Dev HUD: when on, draws a marker at the recorded cursor's video-pixel
  // position so we can visually confirm the zoom focal is tracking it.
  bool _showZoomDebug = false;

  @override
  void initState() {
    super.initState();
    _undoRedo = UndoRedoController<TrimSelection>();
    _frameSettings = FrameSettingsProvider();
    _frameSettings.load();
    _frameSettings.addListener(_onFrameSettingsChanged);
    _initializeVideo();
  }

  void _onFrameSettingsChanged() {
    setState(() {});
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

  @override
  void dispose() {
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

  void _handleZoomRegionSelected(Rect rect) {
    if (!_isInitialized) return;

    final videoDuration = _controller.value.duration;
    if (videoDuration <= Duration.zero) return;

    const desired = Duration(seconds: 2);
    // Default to 2s, but never longer than the video itself.
    final span = videoDuration < desired ? videoDuration : desired;

    var start = _controller.value.position;
    var end = start + span;
    // Keep the zoom inside the video timeline. If the playhead is near the
    // end and the default span would overflow, shift the start back so the
    // zoom ends at the video's end.
    if (end > videoDuration) {
      end = videoDuration;
      start = end - span;
      if (start < Duration.zero) start = Duration.zero;
    }

    final zoomRegion = ZoomRegion(
      rect: rect,
      startTime: start,
      duration: end - start,
      zoomLevel: 2.0,
      videoBounds: Size(
        _controller.value.size.width,
        _controller.value.size.height,
      ),
    );

    setState(() {
      _zoomRegions = [..._zoomRegions, zoomRegion];
      _isSelectingZoom = false;
    });
  }

  void _toggleZoomSelector() {
    setState(() {
      _isSelectingZoom = !_isSelectingZoom;
    });
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

  Future<void> _showExportDialog() async {
    final preset = await showDialog<ExportPreset>(
      context: context,
      builder: (context) => const ExportDialog(),
    );
    if (preset == null || !mounted) return;

    // Resolve output path beside the source.
    final src = File(widget.videoPath);
    final dir = src.parent.path;
    final stem = src.uri.pathSegments.last.split('.').first;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final out = '$dir/${stem}_export_${preset.name}_$ts.mp4';

    // Load source metadata + cursor sidecar (best-effort).
    final meta = await RecordingMetadata.loadForVideo(widget.videoPath);
    CursorRecording cursorRec;
    try {
      cursorRec = await CursorRecording.loadFromFile('${widget.videoPath}.cursor.json');
    } catch (_) {
      cursorRec = CursorRecording();
    }

    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );

    try {
      final pipeline = ExportPipeline(
        sourcePath: widget.videoPath,
        outputPath: out,
        sourceMetadata: meta,
        cursorRecording: cursorRec,
        bitrateKbps: preset.bitrateKbps,
        outputWidth: preset.width,
        outputHeight: preset.height,
        outputFps: preset.fps,
      );
      final summary = await pipeline.run();
      if (!mounted) return;
      Navigator.of(context).pop(); // close progress dialog
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(summary.pass
            ? 'Export complete: ${preset.name} (${summary.realtimeMultiple.toStringAsFixed(1)}× real-time)'
            : 'Export complete (slower than real-time): $out'),
        backgroundColor: summary.pass ? const Color(0xFF4CAF50) : Colors.orange,
      ));
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Export failed: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
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
                    InspectorPanel(frameSettings: _frameSettings),
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

    // The Transform rebuilds every frame, but the expensive parts of the
    // tree above (frame shadow, gradient backdrop, ClipRRect) sit OUTSIDE
    // this AnimatedBuilder, and the VideoPlayer is held as `child` so it
    // isn't reconstructed each frame.
    //
    // The focal is the zoom region's stored rect center (where the user
    // clicked when creating the zoom). True cursor-follow would require
    // recording-region origin + backing scale in the metadata sidecar so
    // we could translate captured screen-global cursor points into video
    // pixels — that's a larger refactor.
    final Widget videoWidget = AnimatedBuilder(
      animation: Listenable.merge([_controller, _smoothPlayhead]),
      child: VideoPlayer(_controller),
      builder: (context, child) {
        final pos = _smoothPlayhead?.position ?? _controller.value.position;
        final focalUpdate = _zoomFocalController.update(
          position: pos,
          zoomRegions: _zoomRegions,
          cursorRecording: _cursorRecording,
        );
        if (focalUpdate == null) return child!;

        final activeZoom = focalUpdate.zoom;
        final focalForFrame = focalUpdate.focal;

        // Smoothly interpolate the rendered zoom level when the user
        // changes it via the badge — otherwise stepping the level
        // produces a visual snap.
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: activeZoom.zoomLevel),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          builder: (context, animatedZoom, _) {
            final tweenedRegion =
                activeZoom.copyWith(zoomLevel: animatedZoom);
            final transform = _zoomTransformer.getTransform(
              position: pos,
              zoomRegion: tweenedRegion,
              videoSize: _controller.value.size,
              focalPoint: focalForFrame,
            );
            return Transform(
              transform: transform,
              alignment: Alignment.center,
              child: child,
            );
          },
        );
      },
    );

    // Calculate the total size including frame padding
    final videoSize = _controller.value.size;
    final currentFrame = _frameSettings.currentFrame;
    final totalSize = FramePainter.calculateTotalSize(
      frame: currentFrame,
      videoSize: videoSize,
    );

    // Wrap video with frame using CustomPaint
    Widget framedVideo = SizedBox(
      width: totalSize.width,
      height: totalSize.height,
      child: Stack(
        children: [
          // Frame background and border
          CustomPaint(
            size: totalSize,
            painter: FramePainter(
              frame: currentFrame,
              videoSize: videoSize,
            ),
          ),
          // Video content with padding and clipping
          Positioned(
            left: currentFrame.padding.left,
            top: currentFrame.padding.top,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(currentFrame.cornerRadius),
              child: SizedBox(
                width: videoSize.width,
                height: videoSize.height,
                child: ZoomSelector(
                  enabled: _isSelectingZoom,
                  videoSize: videoSize,
                  onRegionSelected: _handleZoomRegionSelected,
                  child: videoWidget,
                ),
              ),
            ),
          ),
          if (_metadata?.isPureSource == true && _cursorRecording.count > 0)
            Positioned(
              left: currentFrame.padding.left,
              top: currentFrame.padding.top,
              child: SizedBox(
                width: videoSize.width,
                height: videoSize.height,
                child: AnimatedBuilder(
                  animation:
                      Listenable.merge([_controller, _smoothPlayhead]),
                  builder: (context, _) => CustomPaint(
                    painter: CursorOverlayPainter(
                      cursorRecording: _cursorRecording,
                      position: _smoothPlayhead?.position ??
                          _controller.value.position,
                      videoSize: videoSize,
                      screenSize: videoSize,
                    ),
                  ),
                ),
              ),
            ),
          // Dev HUD: marks the recorded cursor's video-pixel position so
          // we can verify the zoom focal is tracking the cursor. Painted
          // last so it sits on top of the video and any other overlays.
          if (_showZoomDebug)
            Positioned(
              left: currentFrame.padding.left,
              top: currentFrame.padding.top,
              child: IgnorePointer(
                child: SizedBox(
                  width: videoSize.width,
                  height: videoSize.height,
                  child: AnimatedBuilder(
                    animation:
                        Listenable.merge([_controller, _smoothPlayhead]),
                    builder: (context, _) => CustomPaint(
                      painter: _ZoomFocalDebugPainter(
                        cursorRecording: _cursorRecording,
                        position: _smoothPlayhead?.position ??
                            _controller.value.position,
                        videoSize: videoSize,
                        smoothedFocal: _zoomFocalController.smoothedFocal,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return AspectRatio(
      aspectRatio: totalSize.width / totalSize.height,
      child: FittedBox(
        fit: BoxFit.contain,
        child: framedVideo,
      ),
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
          // Time labels (driven by smooth playhead so the timer counts up frame-by-frame).
          AnimatedBuilder(
            animation:
                Listenable.merge([_controller, _smoothPlayhead]),
            builder: (context, _) {
              final pos = _hoverFrozenPosition ??
                  (_smoothPlayhead?.position ?? _controller.value.position);
              final dur = _controller.value.duration;
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_formatDuration(pos),
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12)),
                  Text(_formatDuration(dur),
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12)),
                ],
              );
            },
          ),
          const SizedBox(height: 8),

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
                  setState(() => _selectedZoomIndex = i);
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

              // Zoom button
              IconButton(
                onPressed: _toggleZoomSelector,
                icon: Icon(_isSelectingZoom ? Icons.zoom_in : Icons.zoom_out_map),
                color: _isSelectingZoom ? const Color(0xFF6C63FF) : Colors.white70,
                tooltip: 'Add Zoom Effect',
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

          // Play/Pause and Record Another buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Play/Pause button
              ValueListenableBuilder(
                valueListenable: _controller,
                builder: (context, VideoPlayerValue value, child) {
                  return IconButton(
                    onPressed: () {
                      setState(() {
                        if (value.isPlaying) {
                          _controller.pause();
                        } else {
                          _controller.play();
                        }
                      });
                    },
                    icon: Icon(
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 48,
                    ),
                    color: const Color(0xFF6C63FF),
                  );
                },
              ),

              const SizedBox(width: 32),

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
                onPressed: _showExportDialog,
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


/// Dev HUD overlay drawn on top of the video while debugging cursor-follow
/// zoom. Renders the recorded cursor's position at the current playback
/// time (in video-pixel coords as stored in the .cursor.json sidecar) plus
/// the smoothed focal point that the zoom transformer is currently using,
/// with a small text readout. Off by default; toggled via the AppBar HUD
/// button.
class _ZoomFocalDebugPainter extends CustomPainter {
  _ZoomFocalDebugPainter({
    required this.cursorRecording,
    required this.position,
    required this.videoSize,
    required this.smoothedFocal,
  });

  final CursorRecording cursorRecording;
  final Duration position;
  final Size videoSize;
  final Offset? smoothedFocal;

  @override
  void paint(Canvas canvas, Size size) {
    final raw = cursorAt(cursorRecording, position);
    final scaleX = size.width / videoSize.width;
    final scaleY = size.height / videoSize.height;

    // Trail: render every recorded cursor sample as a small dot, colored
    // by time (early=blue → late=red). Lets you see whether the saved
    // cursor path roughly matches the path you actually moved during
    // recording. If the trail looks completely different, the native
    // transform is producing wrong coordinates.
    final all = cursorRecording.positions;
    if (all.length > 1) {
      final n = all.length;
      final dotPaint = Paint();
      for (var i = 0; i < n; i++) {
        final p = all[i];
        final t = i / (n - 1);
        // HSL: 220° (blue) → 0° (red). Saturation 0.9, lightness 0.5.
        final hue = 220.0 * (1 - t);
        dotPaint.color = HSLColor.fromAHSL(0.6, hue, 0.9, 0.55).toColor();
        canvas.drawCircle(
            Offset(p.x * scaleX, p.y * scaleY), 2, dotPaint);
      }
    }

    if (raw != null) {
      final p = Offset(raw.x * scaleX, raw.y * scaleY);
      // Raw cursor: small filled cyan dot with black outline.
      canvas.drawCircle(p, 6,
          Paint()..color = const Color(0xCC00E5FF));
      canvas.drawCircle(
        p,
        6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.black87,
      );
    }

    if (smoothedFocal != null) {
      final f = Offset(smoothedFocal!.dx * scaleX, smoothedFocal!.dy * scaleY);
      // Smoothed focal: hollow yellow ring + crosshair.
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFFC107);
      canvas.drawCircle(f, 14, ringPaint);
      canvas.drawLine(Offset(f.dx - 18, f.dy), Offset(f.dx + 18, f.dy), ringPaint);
      canvas.drawLine(Offset(f.dx, f.dy - 18), Offset(f.dx, f.dy + 18), ringPaint);
    }

    // Text readout — top-left of the video.
    final readout = StringBuffer();
    readout.writeln('samples: ${cursorRecording.count}');
    if (raw == null) {
      readout.writeln('cursor: <none at this time>');
    } else {
      readout.writeln('cursor: ${raw.x.toStringAsFixed(0)}, ${raw.y.toStringAsFixed(0)} px');
    }
    if (smoothedFocal != null) {
      readout.writeln(
          'focal:  ${smoothedFocal!.dx.toStringAsFixed(0)}, ${smoothedFocal!.dy.toStringAsFixed(0)} px');
    } else {
      readout.writeln('focal:  <no active zoom>');
    }
    if (cursorRecording.positions.isNotEmpty) {
      final xs = cursorRecording.positions.map((p) => p.x);
      final ys = cursorRecording.positions.map((p) => p.y);
      readout.writeln(
          'x rng:  ${xs.reduce((a, b) => a < b ? a : b).toStringAsFixed(0)} … ${xs.reduce((a, b) => a > b ? a : b).toStringAsFixed(0)}');
      readout.writeln(
          'y rng:  ${ys.reduce((a, b) => a < b ? a : b).toStringAsFixed(0)} … ${ys.reduce((a, b) => a > b ? a : b).toStringAsFixed(0)}');
    }
    readout.write('video:  ${videoSize.width.toStringAsFixed(0)} × ${videoSize.height.toStringAsFixed(0)}');
    final tp = TextPainter(
      text: TextSpan(
        text: readout.toString(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
          shadows: [
            Shadow(color: Colors.black, blurRadius: 4),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pad = 6.0;
    final bg = Rect.fromLTWH(8, 8, tp.width + pad * 2, tp.height + pad * 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(bg, const Radius.circular(4)),
      Paint()..color = const Color(0xAA000000),
    );
    tp.paint(canvas, Offset(bg.left + pad, bg.top + pad));
  }

  @override
  bool shouldRepaint(_ZoomFocalDebugPainter old) =>
      old.position != position ||
      old.cursorRecording != cursorRecording ||
      old.videoSize != videoSize ||
      old.smoothedFocal != smoothedFocal;
}
