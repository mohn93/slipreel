import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Shortcuts tab — enables and styles the keystroke overlay that shows
/// captured keyboard shortcuts on the canvas during playback and export,
/// and toggles the shortcuts timeline lane in the editor.
class ShortcutsTab extends ConsumerWidget {
  const ShortcutsTab({super.key, this.hasKeystrokeData = false});

  /// Whether the current recording has any captured keystroke data.
  /// When false the overlay toggle is dimmed with an explanation.
  final bool hasKeystrokeData;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final project = ref.watch(editorProjectControllerProvider);
    final settings = project.keystrokeOverlay;
    final notifier = ref.read(editorProjectControllerProvider.notifier);

    void update(KeystrokeOverlaySettings next) =>
        notifier.setKeystrokeOverlay(next);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        // ── Section label ────────────────────────────────────────────────
        const Text(
          'Shortcuts',
          style: TextStyle(
            color: kInspectorMuted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),

        // ── Show shortcuts toggle ────────────────────────────────────────
        InspectorToggle(
          label: 'Show shortcuts',
          value: settings.enabled,
          onChanged: hasKeystrokeData
              ? (v) => update(settings.copyWith(enabled: v))
              : null,
          subtitle: hasKeystrokeData
              ? 'Show pressed shortcut labels in the video.'
              : 'No keystroke data — record with Accessibility enabled.',
        ),

        if (settings.enabled) ...[
          const SizedBox(height: 24),

          // ── Shortcut labels size ───────────────────────────────────────
          InspectorSlider(
            label: 'Shortcut labels size',
            value: settings.labelScale,
            min: KeystrokeOverlaySettings.minLabelScale,
            max: KeystrokeOverlaySettings.maxLabelScale,
            onChanged: (v) => update(settings.copyWith(labelScale: v)),
            onReset: () => update(settings.copyWith(
              labelScale: KeystrokeOverlaySettings.defaultLabelScale,
            )),
            canReset: settings.labelScale !=
                KeystrokeOverlaySettings.defaultLabelScale,
          ),

          const SizedBox(height: 20),

          // ── Show single key shortcuts ──────────────────────────────────
          InspectorToggle(
            label: 'Show single key shortcuts',
            value: settings.showSingleKeyShortcuts,
            onChanged: (v) =>
                update(settings.copyWith(showSingleKeyShortcuts: v)),
            subtitle: 'By default, only 2+ keys shortcuts are shown. '
                'Enable this option to show single key shortcuts '
                '(Space, Enter, arrows…) as well.',
          ),

          const SizedBox(height: 20),

          // ── One at a time ──────────────────────────────────────────────
          InspectorToggle(
            label: 'Show one at a time',
            value: settings.singleBox,
            onChanged: (v) => update(settings.copyWith(singleBox: v)),
            subtitle: 'Show only the latest shortcut instead of a stack. '
                'Repeats pulse the box and show a ×N count.',
          ),

          const InspectorSectionDivider(),

          // ── Timeline show/hide ─────────────────────────────────────────
          _TimelineToggleButton(
            visible: settings.showTimeline,
            onTap: () =>
                update(settings.copyWith(showTimeline: !settings.showTimeline)),
          ),
        ],
      ],
    );
  }
}

/// Full-width pill button that shows/hides the shortcuts timeline lane.
class _TimelineToggleButton extends StatelessWidget {
  const _TimelineToggleButton({required this.visible, required this.onTap});

  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SpringHoverButton(
      onTap: onTap,
      borderRadius: 8,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kInspectorBorder),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.keyboard_command_key,
              size: 16,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            Text(
              visible ? 'Hide shortcuts timeline' : 'Show shortcuts timeline',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
