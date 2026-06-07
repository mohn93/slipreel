import 'package:flutter/material.dart';

import '../../bar/spring_hover_button.dart';
import '../../theme/app_palette_context.dart';
import '../springy_icon_button.dart';

/// Shared visual building blocks for the inspector tabs. Kept in one
/// place so every tab has the same chip / slider / toggle styling.

const Color kInspectorBg = Color(0xFF1A1A26);
const Color kInspectorPanel = Color(0xFF22222F);
const Color kInspectorAccent = Color(0xFF6C63FF);
const Color kInspectorBorder = Color(0xFF35354A);
const Color kInspectorMuted = Color(0xFF8A8A9A);

/// Section-level title above a group of controls.
class InspectorSectionLabel extends StatelessWidget {
  const InspectorSectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Thin divider used between major sections inside a tab.
class InspectorSectionDivider extends StatelessWidget {
  const InspectorSectionDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Divider(
        height: 1,
        thickness: 1,
        color: context.palette.dividerSubtle,
      ),
    );
  }
}

/// Selectable pill chip — text + optional leading icon. Wraps
/// [SpringHoverButton] so hover gives the magnetic lean / 3D tilt /
/// press-shrink the rest of the editor uses.
///
/// Two visual variants:
///   - default: 16×10 padding, 12px radius, border-flip selected
///     style (matches wallpaper-category / audio-preset / slice-speed
///     chips).
///   - `dense: true`: 12×8 padding, 8px radius, 12pt text, *filled*
///     selected style (tinted body + tinted border + accent text). Used
///     by the cursor-tab preset strip where chips need to feel less
///     heavy than the wallpaper-grade pills above.
///
/// Picked up by [InspectorChipGroup] and any per-tab Wrap of pills, so
/// the four near-identical InkWell variants that used to live in
/// audio/cursor/slice all consolidate here.
class InspectorChip extends StatelessWidget {
  const InspectorChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final double radius = dense ? 8 : 12;
    final EdgeInsets padding = dense
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 10);
    final double fontSize = dense ? 12 : 13;
    final FontWeight fontWeight =
        dense ? FontWeight.w600 : FontWeight.w500;

    final Color bg;
    final Color borderColor;
    final Color textColor;
    if (selected && dense) {
      bg = kInspectorAccent.withValues(alpha: 0.15);
      borderColor = kInspectorAccent.withValues(alpha: 0.5);
      textColor = kInspectorAccent;
    } else if (selected) {
      bg = kInspectorPanel;
      borderColor = kInspectorAccent;
      textColor = Colors.white;
    } else {
      bg = kInspectorPanel;
      borderColor = kInspectorBorder;
      textColor = Colors.white;
    }

    return SpringHoverButton(
      onTap: onTap,
      borderRadius: radius,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, color: textColor, size: 16),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: fontSize,
                fontWeight: fontWeight,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal scrolling row of pill chips. One can be selected.
class InspectorChipGroup<T> extends StatelessWidget {
  const InspectorChipGroup({
    super.key,
    required this.items,
    required this.labelOf,
    required this.selected,
    required this.onSelected,
    this.iconOf,
  });

  final List<T> items;
  final String Function(T) labelOf;
  final IconData? Function(T)? iconOf;
  final T? selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final item in items) ...[
            InspectorChip(
              label: labelOf(item),
              icon: iconOf?.call(item),
              selected: item == selected,
              onTap: () => onSelected(item),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// Horizontal row of square option tiles, used for cursor styles and
/// animation-style pickers. Each tile shows an optional icon and an
/// optional caption underneath.
class InspectorOptionRow<T> extends StatelessWidget {
  const InspectorOptionRow({
    super.key,
    required this.items,
    required this.iconOf,
    required this.labelOf,
    required this.selected,
    required this.onSelected,
    this.tileSize = 64,
  });

  final List<T> items;
  final Widget Function(T) iconOf;
  final String? Function(T) labelOf;
  final T selected;
  final ValueChanged<T> onSelected;
  final double tileSize;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final item in items) _tile(item),
      ],
    );
  }

  Widget _tile(T item) {
    final isSelected = item == selected;
    final label = labelOf(item);
    // SpringHoverButton wraps just the tile body (not the caption) so
    // the springy lean/tilt feels like it belongs to the icon square,
    // not to the unrelated text below it.
    return SizedBox(
      width: tileSize,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SpringHoverButton(
            onTap: () => onSelected(item),
            borderRadius: 12,
            child: Container(
              width: tileSize,
              height: tileSize,
              decoration: BoxDecoration(
                color: kInspectorPanel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      isSelected ? kInspectorAccent : kInspectorBorder,
                  width: 1,
                ),
              ),
              alignment: Alignment.center,
              child: iconOf(item),
            ),
          ),
          if (label != null) ...[
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Slider row with optional Reset button on the right.
class InspectorSlider extends StatelessWidget {
  const InspectorSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onReset,
    this.canReset = true,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final VoidCallback? onReset;
  final bool canReset;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: const TextStyle(
              color: kInspectorMuted,
              fontSize: 12,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  activeTrackColor: kInspectorAccent,
                  inactiveTrackColor: const Color(0xFF35354A),
                  thumbColor: kInspectorAccent,
                  overlayColor: kInspectorAccent.withValues(alpha: 0.16),
                  thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8),
                ),
                child: Slider(
                  value: value.clamp(min, max),
                  min: min,
                  max: max,
                  onChanged: onChanged,
                ),
              ),
            ),
            if (onReset != null) ...[
              const SizedBox(width: 12),
              _ResetButton(
                onPressed: canReset ? onReset : null,
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _ResetButton extends StatelessWidget {
  const _ResetButton({this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SpringHoverButton(
      onTap: onPressed,
      borderRadius: 8,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kInspectorBorder),
        ),
        child: Text(
          'Reset',
          style: TextStyle(
            color: enabled ? Colors.white : Colors.white24,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Toggle row: label (+ optional subtitle / leading icon) and a Switch.
class InspectorToggle extends StatelessWidget {
  const InspectorToggle({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.leadingIcon,
  });

  final String label;
  final String? subtitle;
  final IconData? leadingIcon;
  final bool value;
  /// When null, the toggle renders disabled (no interaction, dimmed
  /// labels). Use this for options that don't apply to the current
  /// context (e.g., features that need data the recording doesn't have).
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final disabled = onChanged == null;
    final labelColor = disabled ? Colors.white38 : Colors.white;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (leadingIcon != null) ...[
                    Icon(leadingIcon,
                        size: 16,
                        color: disabled ? Colors.white30 : Colors.white70),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: labelColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: TextStyle(
                    color: disabled ? Colors.white24 : kInspectorMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        Switch(
          value: value,
          activeThumbColor: kInspectorAccent,
          inactiveTrackColor: const Color(0xFF2A2A38),
          inactiveThumbColor: const Color(0xFF6E6E80),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// Collapsible section that mimics the "Click effect" / "Advanced
/// motion blur settings" rows in the screenshots — a label on the left
/// and a chevron on the right that expands to reveal child controls.
class InspectorCollapsible extends StatefulWidget {
  const InspectorCollapsible({
    super.key,
    required this.title,
    this.subtitle,
    this.child,
    this.initiallyExpanded = false,
  });

  final String title;
  final String? subtitle;
  final Widget? child;
  final bool initiallyExpanded;

  @override
  State<InspectorCollapsible> createState() =>
      _InspectorCollapsibleState();
}

class _InspectorCollapsibleState extends State<InspectorCollapsible> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    // Outer InkWell keeps the whole row tappable; SpringyIconButton's
    // own opaque GestureDetector absorbs taps that land on the chevron
    // so toggling fires exactly once either way.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                SpringyIconButton(
                  icon: _expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  tooltip: _expanded ? 'Collapse' : 'Expand',
                  isActive: false,
                  onTap: _toggle,
                  size: 28,
                  iconSize: 18,
                  tooltipPlacement: SpringyTooltipPlacement.bottom,
                ),
              ],
            ),
          ),
        ),
        if (_expanded && widget.child != null) ...[
          const SizedBox(height: 12),
          widget.child!,
        ],
      ],
    );
  }
}

/// Centered "coming soon" placeholder for tabs without functionality
/// wired up yet.
class InspectorPlaceholder extends StatelessWidget {
  const InspectorPlaceholder({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40, color: kInspectorMuted),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kInspectorMuted,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
