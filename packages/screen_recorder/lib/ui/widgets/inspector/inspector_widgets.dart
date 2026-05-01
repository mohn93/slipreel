import 'package:flutter/material.dart';

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
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Divider(height: 1, thickness: 1, color: Color(0xFF2A2A38)),
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
            _chip(item),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _chip(T item) {
    final isSelected = item == selected;
    final icon = iconOf?.call(item);
    return InkWell(
      onTap: () => onSelected(item),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? kInspectorAccent : kInspectorBorder,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, color: Colors.white, size: 16),
              const SizedBox(width: 6),
            ],
            Text(
              labelOf(item),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
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
    return InkWell(
      onTap: () => onSelected(item),
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: tileSize,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
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
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
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
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
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
                        size: 16, color: Colors.white70),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
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
                  style: const TextStyle(
                    color: kInspectorMuted,
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
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
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: kInspectorPanel,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: kInspectorBorder),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: Colors.white70,
                    size: 18,
                  ),
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
