import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Muted, looping, autoplaying clip used in the onboarding feature
/// showcase. The clips are the same short "beats" the landing page uses.
///
/// Robust by design: if the platform video plugin is unavailable (e.g. a
/// headless widget test) or initialization fails for any reason, the widget
/// silently falls back to the poster image so onboarding never shows a broken
/// or spinning box. Key this widget by [assetPath] so switching features
/// disposes the old controller and spins up a fresh one.
class OnboardingVideo extends StatefulWidget {
  const OnboardingVideo({
    super.key,
    required this.assetPath,
    required this.posterPath,
  });

  /// Bundled `assets/onboarding/*.mp4` path.
  final String assetPath;

  /// Bundled poster shown before the first frame decodes and whenever the
  /// video can't play.
  final String posterPath;

  @override
  State<OnboardingVideo> createState() => _OnboardingVideoState();
}

class _OnboardingVideoState extends State<OnboardingVideo> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final c = VideoPlayerController.asset(widget.assetPath);
      _controller = c;
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(0);
      if (!mounted) {
        await c.dispose();
        return;
      }
      // Fire-and-forget: a slow first frame shouldn't block the flip to ready.
      unawaited(c.play());
      setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final poster = Image.asset(
      widget.posterPath,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) =>
          Container(color: Colors.white.withValues(alpha: 0.04)),
    );

    final Widget child;
    if (_ready && _controller != null) {
      child = FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: _controller!.value.size.width,
          height: _controller!.value.size.height,
          child: VideoPlayer(_controller!),
        ),
      );
    } else {
      // Not ready yet, or failed: poster fill (with a faint loader while we
      // wait, none on outright failure).
      child = Stack(
        fit: StackFit.expand,
        children: [
          poster,
          if (!_failed)
            const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      );
    }

    return AspectRatio(
      aspectRatio: 16 / 10,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: child,
      ),
    );
  }
}
