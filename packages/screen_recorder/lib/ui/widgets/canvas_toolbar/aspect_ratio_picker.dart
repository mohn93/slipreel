import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/output_aspect.dart';

/// Compact button + dropdown that lets the user pick an output aspect
/// ratio. Pure widget: no Riverpod inside — parent wires the state.
class AspectRatioPicker extends StatelessWidget {
  const AspectRatioPicker({
    super.key,
    required this.current,
    required this.onChanged,
  });

  final OutputAspect current;
  final ValueChanged<OutputAspect> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MenuAnchor(
      builder: (context, controller, _) {
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_iconFor(current), size: 18),
                const SizedBox(width: 8),
                Text(current.label, style: theme.textTheme.bodyMedium),
                const SizedBox(width: 4),
                const Icon(Icons.expand_more, size: 18),
              ],
            ),
          ),
        );
      },
      menuChildren: [
        for (final v in OutputAspect.values)
          MenuItemButton(
            leadingIcon: Icon(_iconFor(v), size: 18),
            trailingIcon: v == current
                ? const Icon(Icons.check, size: 18)
                : const SizedBox(width: 18),
            onPressed: () => onChanged(v),
            child: Text(v.label),
          ),
      ],
    );
  }

  IconData _iconFor(OutputAspect v) => switch (v) {
        OutputAspect.auto => Icons.aspect_ratio,
        OutputAspect.wide16x9 || OutputAspect.classic4x3 => Icons.crop_landscape,
        OutputAspect.square1x1 => Icons.crop_square,
        OutputAspect.vertical9x16 ||
        OutputAspect.tall3x4 ||
        OutputAspect.portrait4x5 =>
          Icons.crop_portrait,
      };
}
