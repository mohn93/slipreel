import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

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

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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

                  // Progress slider
                  SliderTheme(
                    data: SliderThemeData(
                      activeTrackColor: const Color(0xFF6C63FF),
                      inactiveTrackColor: Colors.white24,
                      thumbColor: const Color(0xFF6C63FF),
                      overlayColor: const Color(0xFF6C63FF).withOpacity(0.2),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      value: value.position.inMilliseconds.toDouble(),
                      min: 0,
                      max: value.duration.inMilliseconds.toDouble(),
                      onChanged: (newValue) {
                        _controller.seekTo(
                          Duration(milliseconds: newValue.toInt()),
                        );
                      },
                    ),
                  ),
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
