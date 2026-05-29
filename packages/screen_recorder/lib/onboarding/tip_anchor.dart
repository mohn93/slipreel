import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'tips_controller.dart';
import 'tip_overlay.dart';

class TipAnchor extends ConsumerStatefulWidget {
  const TipAnchor({super.key, required this.tipId, required this.child});

  final TipId tipId;
  final Widget child;

  @override
  ConsumerState<TipAnchor> createState() => _TipAnchorState();
}

class _TipAnchorState extends ConsumerState<TipAnchor> {
  final _key = GlobalKey();
  OverlayEntry? _entry;
  // Cached so we can call release() safely in dispose() after ref is gone.
  TipsController? _cachedController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryShow());
  }

  void _tryShow() {
    if (!mounted) return;
    final controller = ref.read(tipsControllerProvider);
    _cachedController = controller;
    if (!controller.shouldShow(widget.tipId)) return;
    final ctx = _key.currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    if (!controller.tryClaim(widget.tipId)) return;

    final offset = box.localToGlobal(Offset.zero);
    final rect = offset & box.size;
    _entry = OverlayEntry(
      builder: (_) => TipOverlay(
        anchorRect: rect,
        message: controller.copyFor(widget.tipId),
        onDismiss: _dismiss,
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  Future<void> _dismiss() async {
    final controller = ref.read(tipsControllerProvider);
    _entry?.remove();
    _entry = null;
    controller.release(widget.tipId);
    await controller.markSeen(widget.tipId);
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    _cachedController?.release(widget.tipId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Container(key: _key, child: widget.child);
}
