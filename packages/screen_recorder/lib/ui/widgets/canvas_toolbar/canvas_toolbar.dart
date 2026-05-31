import 'package:flutter/material.dart';

/// Slim horizontal toolbar that sits above the playback canvas. Holds
/// canvas-scoped controls (aspect picker today; mask / frame picker
/// next). Centered, fixed height so the layout doesn't reflow when
/// children update.
class CanvasToolbar extends StatelessWidget {
  const CanvasToolbar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 16),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}
