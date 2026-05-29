import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/countdown_controller.dart';

/// Renders inside the existing bar window. When the controller is active,
/// hides the bar's source picker behind a translucent backdrop and shows a
/// big centered countdown number with a Cancel button.
class CountdownOverlay extends ConsumerWidget {
  const CountdownOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(countdownControllerProvider);
    if (!state.active) return const SizedBox.shrink();

    return SizedBox.expand(
      child: ColoredBox(
        color: const Color(0xB3000000),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.6, end: 1.0),
                key: ValueKey(state.remaining),
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutBack,
                builder: (_, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: Text(
                  '${state.remaining}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 44,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 24),
              TextButton(
                onPressed: () =>
                    ref.read(countdownControllerProvider.notifier).cancel(),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
