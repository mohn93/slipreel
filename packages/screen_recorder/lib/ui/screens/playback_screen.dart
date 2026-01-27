import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:screen_recorder/models/trim_selection.dart';
import 'package:screen_recorder/state/undo_redo_controller.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_widget.dart';

class PlaybackScreen extends StatefulWidget {
  final String videoPath;

  const PlaybackScreen({
    super.key,
    required this.videoPath,
  });

  @override
  State<PlaybackScreen> createState() => _PlaybackScreenState();
}

class _PlaybackScreenState extends State<PlaybackScreen> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  String? _error;
  TrimSelection? _trimSelection;
  final _undoRedoController = UndoRedoController<TrimSelection>();

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      _controller = VideoPlayerController.file(File(widget.videoPath));
      await _controller.initialize();
      setState(() {
        _isInitialized = true;
        // Initialize trim selection to full duration
        _trimSelection = TrimSelection(
          start: Duration.zero,
          end: _controller.value.duration,
          videoDuration: _controller.value.duration,
        );
        // Push initial state to undo/redo controller
        _undoRedoController.push(_trimSelection!);
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
    _controller.dispose();
    super.dispose();
  }

  void _handleUndo() {
    if (_undoRedoController.canUndo) {
      final previousState = _undoRedoController.undo();
      if (previousState != null) {
        setState(() {
          _trimSelection = previousState;
        });
      }
    }
  }

  void _handleRedo() {
    if (_undoRedoController.canRedo) {
      final nextState = _undoRedoController.redo();
      if (nextState != null) {
        setState(() {
          _trimSelection = nextState;
        });
      }
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
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          // Undo - CMD+Z on macOS, Ctrl+Z on Windows/Linux
          LogicalKeySet(
            Platform.isMacOS ? LogicalKeyboardKey.meta : LogicalKeyboardKey.control,
            LogicalKeyboardKey.keyZ,
          ): const UndoIntent(),
          // Redo - CMD+Shift+Z on macOS, Ctrl+Shift+Z on Windows/Linux
          LogicalKeySet(
            Platform.isMacOS ? LogicalKeyboardKey.meta : LogicalKeyboardKey.control,
            LogicalKeyboardKey.shift,
            LogicalKeyboardKey.keyZ,
          ): const RedoIntent(),
          // Alternative redo - CMD+Y on macOS, Ctrl+Y on Windows/Linux
          LogicalKeySet(
            Platform.isMacOS ? LogicalKeyboardKey.meta : LogicalKeyboardKey.control,
            LogicalKeyboardKey.keyY,
          ): const RedoIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            UndoIntent: CallbackAction<UndoIntent>(
              onInvoke: (UndoIntent intent) {
                _handleUndo();
                return null;
              },
            ),
            RedoIntent: CallbackAction<RedoIntent>(
              onInvoke: (RedoIntent intent) {
                _handleRedo();
                return null;
              },
            ),
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
                // Video player
                Expanded(
                  child: Center(
                    child: _buildVideoPlayer(),
                  ),
                ),

                // Controls
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

    return AspectRatio(
      aspectRatio: _controller.value.aspectRatio,
      child: VideoPlayer(_controller),
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
          // Progress bar
          ValueListenableBuilder(
            valueListenable: _controller,
            builder: (context, VideoPlayerValue value, child) {
              return Column(
                children: [
                  // Time labels
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDuration(value.position),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        _formatDuration(value.duration),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Timeline widget
                  TimelineWidget(
                    duration: value.duration,
                    position: value.position,
                    onPositionChanged: (newPosition) {
                      _controller.seekTo(newPosition);
                    },
                    trimSelection: _trimSelection,
                    onTrimChanged: (newTrim) {
                      setState(() {
                        _trimSelection = newTrim;
                        // Push new state to undo/redo controller
                        _undoRedoController.push(newTrim);
                      });
                    },
                  ),

                  // Trim info display
                  if (_trimSelection != null) ...[
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Trim: ${_formatDuration(_trimSelection!.start)} - ${_formatDuration(_trimSelection!.end)}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '(${_formatDuration(_trimSelection!.duration)})',
                          style: const TextStyle(
                            color: Color(0xFF6C63FF),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),

          const SizedBox(height: 16),

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
            ],
          ),
        ],
      ),
    );
  }
}

/// Intent for undo action.
class UndoIntent extends Intent {
  const UndoIntent();
}

/// Intent for redo action.
class RedoIntent extends Intent {
  const RedoIntent();
}
