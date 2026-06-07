import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Shortcuts tab — enables and styles the keystroke overlay that shows
/// captured keyboard events on the canvas during playback and export.
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
      padding: EdgeInsets.zero,
      children: [
        // ── Enable toggle ────────────────────────────────────────────────
        InspectorToggle(
          label: 'Show overlay',
          value: settings.enabled,
          onChanged: hasKeystrokeData
              ? (v) => update(settings.copyWith(enabled: v))
              : null,
          subtitle: hasKeystrokeData
              ? 'Display captured keystrokes on the canvas'
              : 'No keystroke data — record with Accessibility enabled',
        ),

        if (settings.enabled) ...[
          const InspectorSectionDivider(),

          // ── Position ─────────────────────────────────────────────────
          const InspectorSectionLabel('Position'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: InspectorChipGroup<KeystrokePosition>(
              items: KeystrokePosition.values,
              labelOf: (p) => p.label,
              selected: settings.position,
              onSelected: (p) => update(settings.copyWith(position: p)),
            ),
          ),

          const SizedBox(height: 20),

          // ── Badge size ───────────────────────────────────────────────
          const InspectorSectionLabel('Badge size'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: InspectorChipGroup<KeystrokeSize>(
              items: KeystrokeSize.values,
              labelOf: (s) => s.label,
              selected: settings.size,
              onSelected: (s) => update(settings.copyWith(size: s)),
            ),
          ),

          const SizedBox(height: 20),

          // ── Fade duration ────────────────────────────────────────────
          const InspectorSectionLabel('Fade after'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: InspectorChipGroup<double>(
              items: const [1.0, 2.0, 3.0],
              labelOf: (s) => '${s.toInt()}s',
              selected: settings.fadeSecs,
              onSelected: (s) => update(settings.copyWith(fadeSecs: s)),
            ),
          ),

          const SizedBox(height: 20),
        ],

        // ── Info footer ──────────────────────────────────────────────────
        const InspectorSectionDivider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: Text(
            'Keystroke capture requires Accessibility permission. '
            'Grant it in System Settings → Privacy & Security → Accessibility.',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withAlpha(102),
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
