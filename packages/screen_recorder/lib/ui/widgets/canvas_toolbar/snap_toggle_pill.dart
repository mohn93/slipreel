import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/state/snap_preference_controller.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// Magnet-icon pill that toggles snap-on-cut globally. Sits next to
/// the timeline scale slider in the canvas toolbar.
class SnapTogglePill extends ConsumerWidget {
  const SnapTogglePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(snapPreferenceProvider);
    final palette = context.palette;
    final tooltip = 'Snap to events: ${enabled ? 'On' : 'Off'}';
    return Tooltip(
      message: tooltip,
      child: Material(
        color: enabled ? palette.accentMuted : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: () => ref
              .read(snapPreferenceProvider.notifier)
              .setEnabled(!enabled),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  // `auto_fix_high` reads as "snap/magnet" — a wand with
                  // sparkle. `attractions` (the carousel pictogram) was
                  // the previous choice; replaced because it confused
                  // first-time viewers as a non-tool icon.
                  Icons.auto_fix_high,
                  size: 16,
                  color: enabled ? palette.accent : palette.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Snap',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: enabled ? palette.textPrimary : palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
