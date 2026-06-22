import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

import '../inspector_widgets.dart';

const _swatches = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFFFFEB3B),
  Color(0xFF000000),
  Color(0xFF4FC3F7),
  Color(0xFF81C784),
];

class CaptionStyleControls extends ConsumerWidget {
  const CaptionStyleControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(
      editorProjectControllerProvider.select((s) => s.captionStyle),
    );
    final controller = ref.read(editorProjectControllerProvider.notifier);
    void update(CaptionStyle next) => controller.setCaptionStyle(next);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InspectorToggle(
          label: 'Show captions',
          subtitle: 'Burn captions into the preview and export.',
          value: style.enabled,
          onChanged: (v) => update(style.copyWith(enabled: v)),
        ),
        const SizedBox(height: 8),
        InspectorChipGroup<CaptionPosition>(
          items: CaptionPosition.values,
          labelOf: (p) => p.label,
          selected: style.position,
          onSelected: (p) => update(style.copyWith(position: p)),
        ),
        const SizedBox(height: 8),
        InspectorSlider(
          label: 'Font size',
          subtitle: '${(style.fontScale * 100).round()}%',
          value: style.fontScale,
          min: CaptionStyle.minFontScale,
          max: CaptionStyle.maxFontScale,
          onChanged: (v) => update(style.copyWith(fontScale: v)),
          onReset: () =>
              update(style.copyWith(fontScale: CaptionStyle.defaultFontScale)),
          canReset: style.fontScale != CaptionStyle.defaultFontScale,
        ),
        const SizedBox(height: 8),
        InspectorChipGroup<CaptionBackground>(
          items: CaptionBackground.values,
          labelOf: (b) => b.label,
          selected: style.background,
          onSelected: (b) => update(style.copyWith(background: b)),
        ),
        const SizedBox(height: 12),
        const Text('Text color',
            style: TextStyle(fontSize: 12, color: Colors.white70)),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final c in _swatches)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => update(style.copyWith(textColor: c)),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: style.textColor == c
                            ? Colors.white
                            : Colors.white24,
                        width: style.textColor == c ? 3 : 1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
