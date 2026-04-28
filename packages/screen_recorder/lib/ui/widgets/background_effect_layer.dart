// packages/screen_recorder/lib/ui/widgets/background_effect_layer.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../effects/effect_params.dart';

enum BackgroundKind { none, solid, gradient, blur }

class BackgroundEffectLayer extends StatelessWidget {
  final BackgroundKind kind;
  final Color solidColor;
  final List<Color> gradientColors;
  final Alignment gradientBegin;
  final Alignment gradientEnd;
  final BlurIntensity blurIntensity;

  const BackgroundEffectLayer({
    super.key,
    required this.kind,
    this.solidColor = Colors.black,
    this.gradientColors = const [Color(0xFF6C63FF), Color(0xFF1E1E2E)],
    this.gradientBegin = Alignment.topLeft,
    this.gradientEnd = Alignment.bottomRight,
    this.blurIntensity = BlurIntensity.medium,
  });

  @override
  Widget build(BuildContext context) {
    switch (kind) {
      case BackgroundKind.none:
        return const SizedBox.shrink();
      case BackgroundKind.solid:
        return Positioned.fill(child: Container(color: solidColor));
      case BackgroundKind.gradient:
        return Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: gradientBegin,
                end: gradientEnd,
                colors: gradientColors,
              ),
            ),
          ),
        );
      case BackgroundKind.blur:
        final sigma = blurSigmaForIntensity(blurIntensity);
        return Positioned.fill(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: Container(color: Colors.black12),
          ),
        );
    }
  }
}
