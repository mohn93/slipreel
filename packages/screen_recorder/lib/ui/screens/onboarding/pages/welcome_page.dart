import 'package:flutter/material.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onNext});
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    // The wallpaper backdrop is rendered full-bleed at the onboarding-screen
    // level (see WelcomeBackground) so it also covers the page-dot strip; this
    // page only carries the foreground content.
    return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),
              // App icon with a soft accent glow so it lifts off the backdrop.
              Container(
                width: 104,
                height: 104,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.45),
                      blurRadius: 48,
                      spreadRadius: 2,
                      offset: const Offset(0, 16),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    'assets/onboarding/app_icon.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(Icons.videocam,
                        size: 56, color: theme.colorScheme.primary),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Welcome to Slipreel',
                style: theme.textTheme.displaySmall?.copyWith(
                  shadows: const [
                    Shadow(
                      color: Colors.black87,
                      blurRadius: 18,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Polished screen recordings with smart defaults.',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  shadows: const [
                    Shadow(
                      color: Colors.black87,
                      blurRadius: 14,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              SizedBox(
                width: 240,
                child: FilledButton(
                  onPressed: onNext,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Get started'),
                  ),
                ),
              ),
            ],
          ),
        );
  }
}

/// One of the app's editor wallpapers as the welcome backdrop, with a scrim
/// for text contrast. Rendered full-bleed behind the whole onboarding body
/// (including the page-dot strip) and faded out as the user advances.
class WelcomeBackground extends StatelessWidget {
  const WelcomeBackground({super.key});

  // On-brand purple glow from the editor's Abstract wallpaper set.
  static const _wallpaper = 'assets/wallpapers/abstract/01_purple_glow.jpg';

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          _wallpaper,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              const ColoredBox(color: Color(0xFF0D0D14)),
        ),
        // Scrim: darken top/bottom for legible title, button and page dots.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.45),
                Colors.black.withValues(alpha: 0.20),
                Colors.black.withValues(alpha: 0.55),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}
