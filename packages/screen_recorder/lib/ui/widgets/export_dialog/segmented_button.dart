import 'package:flutter/material.dart';

const Color _kSelectedBorder = Color(0xFF8B5CF6);
const Color _kSelectedFill = Color(0xFF1F1A2E);
const Color _kUnselectedFill = Color(0xFF22232C);
const Color _kLabelColor = Color(0xFFE8E8EA);

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
    required this.selected,
    required this.onChanged,
    this.disabled = const {},
  });

  final List<({T value, String label, String? tooltip})> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final Set<T> disabled;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          _Button<T>(
            option: options[i],
            isSelected: options[i].value == selected,
            isDisabled: disabled.contains(options[i].value),
            onTap: () => onChanged(options[i].value),
          ),
        ],
      ],
    );
  }
}

class _Button<T> extends StatelessWidget {
  const _Button({
    super.key,
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
    final button = Opacity(
      opacity: isDisabled ? 0.4 : 1.0,
      child: GestureDetector(
        key: ValueKey('seg_btn_${option.label}'),
        onTap: (isDisabled || isSelected) ? null : onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: isSelected ? _kSelectedFill : _kUnselectedFill,
            borderRadius: BorderRadius.circular(8),
            border: isSelected
                ? Border.all(color: _kSelectedBorder, width: 1.5)
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            option.label,
            style: const TextStyle(
              color: _kLabelColor,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );

    final tooltip = option.tooltip;
    if (tooltip != null && isDisabled) {
      return Tooltip(message: tooltip, child: button);
    }
    return button;
  }
}
