import 'dart:async';

import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

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
/// hover-highlighted rows.
///
/// Motion matches the app's spring vocabulary: it springs open from the
/// anchored edge (scale + fade with a slight overshoot) and collapses back the
/// same way before the overlay is torn down. Completes with the tapped item's
/// value, or null if dismissed by tapping outside.
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

  // The panel grows from whichever edge sits against the anchor.
  final grow = openUp ? Alignment.bottomCenter : Alignment.topCenter;

  final completer = _SafeCompleter<T?>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _InspectorPopoverLayer<T>(
      left: left,
      top: top,
      width: width,
      grow: grow,
      items: items,
      onClosed: (result) {
        entry.remove();
        completer.complete(result);
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

/// A Completer that ignores a second `complete` (barrier + pick can race).
class _SafeCompleter<T> {
  final _inner = Completer<T>();
  Future<T> get future => _inner.future;
  void complete(T v) {
    if (!_inner.isCompleted) _inner.complete(v);
  }
}

class _InspectorPopoverLayer<T> extends StatefulWidget {
  const _InspectorPopoverLayer({
    required this.left,
    required this.top,
    required this.width,
    required this.grow,
    required this.items,
    required this.onClosed,
  });

  final double left;
  final double top;
  final double width;
  final Alignment grow;
  final List<InspectorPopoverItem<T>> items;

  /// Called once, after the collapse animation, with the chosen value or null.
  final ValueChanged<T?> onClosed;

  @override
  State<_InspectorPopoverLayer<T>> createState() =>
      _InspectorPopoverLayerState<T>();
}

class _InspectorPopoverLayerState<T> extends State<_InspectorPopoverLayer<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 190),
    reverseDuration: const Duration(milliseconds: 150),
  );

  // Springy overshoot on the way in; a calm ease on the way out.
  late final Animation<double> _scale = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );

  bool _closing = false;
  T? _result;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  void _close(T? result) {
    if (_closing) return;
    _closing = true;
    _result = result;
    _controller.reverse().whenComplete(() => widget.onClosed(_result));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => _close(null),
          ),
        ),
        Positioned(
          left: widget.left,
          top: widget.top,
          width: widget.width,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              // Grow mostly along the vertical axis (a dropdown "unrolling"),
              // with a touch of horizontal scale so it feels alive.
              final t = _scale.value;
              return Opacity(
                opacity: _fade.value.clamp(0.0, 1.0),
                child: Transform(
                  alignment: widget.grow,
                  transform: Matrix4.diagonal3Values(
                      0.98 + 0.02 * t, 0.8 + 0.2 * t, 1.0),
                  child: child,
                ),
              );
            },
            child: _PopoverPanel<T>(items: widget.items, onPick: _close),
          ),
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

/// One row. Hover feedback is delegated to [SpringHoverButton] — the exact
/// physics the recording bar's controls use — so the highlight springs from
/// the cursor's entry point, leans magnetically, 3D-tilts the label, and flies
/// off on exit. The selected row carries a persistent accent tint underneath
/// (mirroring the bar's "active" buttons), which the spring pill blends over.
class _PopoverRow<T> extends StatelessWidget {
  const _PopoverRow({required this.item, required this.onPick});

  final InspectorPopoverItem<T> item;
  final ValueChanged<T> onPick;

  @override
  Widget build(BuildContext context) {
    final labelColor = item.destructive
        ? const Color(0xFFFF6B6B)
        : (item.selected ? kInspectorAccent : Colors.white);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: SpringHoverButton(
        onTap: () => onPick(item.value),
        borderRadius: 8,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: item.selected
                ? kInspectorAccent.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
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
