import 'dart:async';

import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Subtle row hover fill — slightly lighter than [kInspectorPanel].
const Color _kPopoverHover = Color(0xFF2E2E3D);

/// One selectable row in an [showInspectorPopover] panel.
class InspectorPopoverItem<T> {
  const InspectorPopoverItem({
    required this.value,
    required this.label,
    this.selected = false,
    this.destructive = false,
    this.dividerBefore = false,
  });

  final T value;
  final String label;

  /// Shows a leading check and accent-tints the label.
  final bool selected;

  /// Renders the label in the danger color (e.g. Delete).
  final bool destructive;

  /// Draws a hairline separator above this row.
  final bool dividerBefore;
}

/// A bespoke dark dropdown panel — deliberately NOT a Material `PopupMenuButton`
/// / `MenuAnchor`. Anchored just below (or above, if it would overflow) the
/// widget at [anchorContext], it renders in the root [Overlay] with the
/// inspector's own palette: rounded panel, hairline border, soft shadow, and
/// hover-highlighted rows. Completes with the tapped item's value, or null if
/// dismissed by tapping outside or pressing Escape.
Future<T?> showInspectorPopover<T>(
  BuildContext anchorContext, {
  required List<InspectorPopoverItem<T>> items,
  double minWidth = 180,
  bool matchAnchorWidth = false,
  bool alignRight = false,
}) async {
  final overlay = Overlay.of(anchorContext);
  final anchorBox = anchorContext.findRenderObject() as RenderBox;
  final overlayBox = overlay.context.findRenderObject() as RenderBox;
  final overlaySize = overlayBox.size;

  final anchorTopLeft = anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox);
  final anchorSize = anchorBox.size;

  final width = matchAnchorWidth ? anchorSize.width : minWidth;

  // Estimated panel height for the flip-up decision (row + separators + pad).
  const rowHeight = 34.0;
  final estHeight =
      items.length * rowHeight + items.where((i) => i.dividerBefore).length + 12;

  final spaceBelow = overlaySize.height - (anchorTopLeft.dy + anchorSize.height);
  final openUp = spaceBelow < estHeight + 12 && anchorTopLeft.dy > estHeight;

  final top = openUp
      ? anchorTopLeft.dy - estHeight - 6
      : anchorTopLeft.dy + anchorSize.height + 6;

  double left = alignRight
      ? anchorTopLeft.dx + anchorSize.width - width
      : anchorTopLeft.dx;
  // Keep the panel on-screen horizontally.
  left = left.clamp(8.0, (overlaySize.width - width - 8).clamp(8.0, double.infinity));

  final completer = _PopoverCompleter<T>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _InspectorPopoverLayer<T>(
      left: left,
      top: top,
      width: width,
      items: items,
      onPick: (v) {
        completer.complete(v);
        entry.remove();
      },
      onDismiss: () {
        completer.complete(null);
        entry.remove();
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _PopoverCompleter<T> {
  final _c = _SafeCompleter<T?>();
  Future<T?> get future => _c.future;
  void complete(T? v) => _c.complete(v);
}

/// A Completer that ignores a second `complete` (barrier + pick can race).
class _SafeCompleter<T> {
  final _inner = Completer<T>();
  Future<T> get future => _inner.future;
  void complete(T v) {
    if (!_inner.isCompleted) _inner.complete(v);
  }
}

class _InspectorPopoverLayer<T> extends StatelessWidget {
  const _InspectorPopoverLayer({
    required this.left,
    required this.top,
    required this.width,
    required this.items,
    required this.onPick,
    required this.onDismiss,
  });

  final double left;
  final double top;
  final double width;
  final List<InspectorPopoverItem<T>> items;
  final ValueChanged<T> onPick;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Full-screen dismiss barrier.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: width,
          child: _PopoverPanel<T>(items: items, onPick: onPick),
        ),
      ],
    );
  }
}

class _PopoverPanel<T> extends StatelessWidget {
  const _PopoverPanel({required this.items, required this.onPick});

  final List<InspectorPopoverItem<T>> items;
  final ValueChanged<T> onPick;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kInspectorBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items) ...[
              if (item.dividerBefore)
                const Divider(height: 5, thickness: 1, color: kInspectorBorder),
              _PopoverRow<T>(item: item, onPick: onPick),
            ],
          ],
        ),
      ),
    );
  }
}

class _PopoverRow<T> extends StatefulWidget {
  const _PopoverRow({required this.item, required this.onPick});

  final InspectorPopoverItem<T> item;
  final ValueChanged<T> onPick;

  @override
  State<_PopoverRow<T>> createState() => _PopoverRowState<T>();
}

class _PopoverRowState<T> extends State<_PopoverRow<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final labelColor = item.destructive
        ? const Color(0xFFFF6B6B)
        : (item.selected ? kInspectorAccent : Colors.white);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onPick(item.value),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 5),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: _hover ? _kPopoverHover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: item.selected
                    ? const Icon(Icons.check, size: 13, color: kInspectorAccent)
                    : null,
              ),
              Expanded(
                child: Text(
                  item.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: labelColor, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
