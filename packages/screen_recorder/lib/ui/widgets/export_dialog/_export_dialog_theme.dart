// Visual contract for the export dialog. Keep all colors and the
// dimensions that ride them in one place — every picker and the
// segmented atom import from here so a tweak to the palette doesn't
// require touching nine files.
import 'package:flutter/material.dart';

const kBgUnselected = Color(0xFF22232C);
const kBgSelected = Color(0xFF1F1A2E);
const kAccent = Color(0xFF8B5CF6);
const kTextPrimary = Color(0xFFE8E8EA);
const kTextSecondary = Color(0xFF8C8C95);
const kBorderSubtle = Color(0xFF35354A);

const kSegmentHeight = 36.0;
const kSegmentRadius = 8.0;
const kSegmentHGap = 8.0;
const kDisabledOpacity = 0.4;

/// A pill-shaped surface shared by [ExportSegmentedButton] buttons and
/// other icon-only buttons in the export dialog (e.g. _RevealButton).
/// Keeping the chrome here means both consumers stay visually in sync.
class PillSurface extends StatelessWidget {
  const PillSurface({
    super.key,
    required this.child,
    this.onTap,
    this.width,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// Optional fixed width. Leave null to let the container size itself.
  final double? width;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: kSegmentHeight,
        decoration: BoxDecoration(
          color: kBgUnselected,
          borderRadius: BorderRadius.circular(kSegmentRadius),
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}
