import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/onboarding_video.dart';

/// One entry in the onboarding feature showcase.
class _Feature {
  const _Feature(this.title, this.blurb, this.asset, this.poster);
  final String title;
  final String blurb;
  final String asset;
  final String poster;
}

const _features = <_Feature>[
  _Feature(
    'Automatic zoom',
    'Slipreel zooms into the action as you click, then eases smoothly back out.',
    'assets/onboarding/beat-zoom.mp4',
    'assets/onboarding/beat-zoom-poster.webp',
  ),
  _Feature(
    'Polished cursor',
    'A smooth, size-adjustable cursor with click highlights — no jitter.',
    'assets/onboarding/beat-cursor.mp4',
    'assets/onboarding/beat-cursor-poster.webp',
  ),
  _Feature(
    'Keystroke overlays',
    'Show the keys you press, styled to match your recording.',
    'assets/onboarding/beat-keystrokes.mp4',
    'assets/onboarding/beat-keystrokes-poster.webp',
  ),
  _Feature(
    'Auto captions',
    'On-device transcription burns in clean, readable captions.',
    'assets/onboarding/beat-captions.mp4',
    'assets/onboarding/beat-captions-poster.webp',
  ),
  _Feature(
    'Backdrops & frames',
    'Drop your recording onto gradients, wallpapers, and device frames.',
    'assets/onboarding/beat-frames.mp4',
    'assets/onboarding/beat-frames-poster.webp',
  ),
];

class FeaturesPage extends StatefulWidget {
  const FeaturesPage({super.key, required this.onNext});
  final VoidCallback onNext;

  @override
  State<FeaturesPage> createState() => _FeaturesPageState();
}

class _FeaturesPageState extends State<FeaturesPage> {
  static const _dwell = Duration(seconds: 5);
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(_dwell, (_) {
      if (!mounted) return;
      setState(() => _index = (_index + 1) % _features.length);
    });
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _arm(); // restart the dwell so a manual pick gets a full look.
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = _features[_index];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text('Built-in polish', style: theme.textTheme.displaySmall),
          const SizedBox(height: 8),
          Text(
            'Every recording gets these automatically.',
            style:
                theme.textTheme.titleMedium?.copyWith(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 32,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: OnboardingVideo(
                    // Key by asset so switching features rebuilds the player.
                    key: ValueKey(f.asset),
                    assetPath: f.asset,
                    posterPath: f.poster,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Column(
              key: ValueKey(_index),
              children: [
                Text(f.title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 6),
                SizedBox(
                  height: 40,
                  child: Text(
                    f.blurb,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_features.length, (i) {
              final active = i == _index;
              return GestureDetector(
                key: ValueKey('feature-dot-$i'),
                onTap: () => _select(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active ? Colors.white : Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 240,
            child: FilledButton(
              onPressed: widget.onNext,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Continue'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
