import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// TODO(slice-editor T11): this widget is replaced by SliceEditor in T11.
/// Stubbed out in T4 (project-globals removal) because it used the now-
/// removed `state.playbackSpeed`/`fadeIn`/`fadeOut` + the deprecated
/// `setPlaybackSpeed`/`setFadeIn`/`setFadeOut` setters. Renders nothing so
/// the inspector still composes during the interim tasks.
class ClipContextInspector extends ConsumerWidget {
  const ClipContextInspector({
    super.key,
    required this.clipDuration,
    required this.onClose,
  });

  final Duration clipDuration;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) => const SizedBox();
}
