// packages/screen_recorder/lib/ui/widgets/canvas_toolbar/snap_toggle_pill.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/state/snap_preference_controller.dart';

/// Magnet-icon pill that toggles snap-on-cut globally. Sits next to
/// the timeline scale slider in the canvas toolbar.
class SnapTogglePill extends ConsumerWidget {
  const SnapTogglePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(snapPreferenceProvider);
    final tooltip = 'Snap to events: ${enabled ? 'On' : 'Off'}';
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => ref
            .read(snapPreferenceProvider.notifier)
            .setEnabled(!enabled),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Icon(
            // `attractions` is the magnet pictogram in Material Icons.
            Icons.attractions,
            size: 18,
            color: enabled
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).disabledColor,
          ),
        ),
      ),
    );
  }
}
