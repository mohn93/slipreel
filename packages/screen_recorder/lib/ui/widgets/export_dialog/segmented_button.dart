import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/_export_dialog_theme.dart';

/// A horizontal row of pill buttons where exactly one option is selected.
///
/// Generic over [T] so each picker works with its own enum or int type.
/// Tapping the currently selected option is a no-op (radio semantics).
///
/// [disabled] holds values that cannot be tapped. Disabled buttons render
/// at 40% opacity. A [Set] (rather than a per-option bool) makes it easy
/// for callers to disable several values at once without rewriting the
/// options list.
class ExportSegmentedButton<T> extends StatelessWidget {
  const ExportSegmentedButton({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.disabled = const {},
  });

  final List<({T value, String label, String? tooltip})> options;
  final T value;
  final ValueChanged<T> onChanged;
  final Set<T> disabled;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: kSegmentHGap,
      children: [
        for (final option in options)
          _Button<T>(
            option: option,
            isSelected: option.value == value,
            isDisabled: disabled.contains(option.value),
            onTap: () => onChanged(option.value),
          ),
      ],
    );
  }
}

class _Button<T> extends StatelessWidget {
  const _Button({
    required this.option,
    required this.isSelected,
    required this.isDisabled,
    required this.onTap,
  });

  final ({T value, String label, String? tooltip}) option;
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final body = Opacity(
      opacity: isDisabled ? kDisabledOpacity : 1.0,
      child: Semantics(
        enabled: !isDisabled,
        button: true,
        selected: isSelected,
        label: option.label,
        child: GestureDetector(
          key: ValueKey('seg_btn_${option.value}'),
          onTap: (isDisabled || isSelected) ? null : onTap,
          child: Container(
            height: kSegmentHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: isSelected ? kBgSelected : kBgUnselected,
              borderRadius: BorderRadius.circular(kSegmentRadius),
              border: isSelected
                  ? Border.all(color: kAccent, width: 1.5)
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(
              option.label,
              style: const TextStyle(
                color: kTextPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );

    Widget result = body;

    if (isDisabled) {
      result = MouseRegion(
        cursor: SystemMouseCursors.forbidden,
        child: result,
      );
    }

    final tooltip = option.tooltip;
    if (tooltip != null) {
      result = Tooltip(message: tooltip, child: result);
    }

    return result;
  }
}
