import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'spring_hover_button.dart';

/// Matches `_kBarButtonHeight` in recording_bar.dart so the chip lines up
/// with the other labelled bar controls.
const double _kBarButtonHeight = 56;

/// Matches `_kMicChipWidth` in recording_bar.dart so the bar doesn't resize
/// as the template name changes — long names ellipsize, icon/chevron stay put.
const double _kChipWidth = 160;

/// Compact chip showing the currently-selected look template: a layout icon,
/// the (truncated) template name, and a chevron — styled like the `_MicControl`/
/// `_SystemAudioControl` chips in `recording_bar.dart` so it reads as part of
/// the same control family. Tapping opens a menu of the available templates
/// via [onTap]; pure presentation, no state of its own.
class TemplateControl extends StatelessWidget {
  const TemplateControl({
    super.key,
    required this.selectedName,
    required this.onTap,
  });

  /// Name of the currently-selected look template (e.g. "Showcase").
  final String selectedName;

  /// Fired when the chip is tapped — opens the template picker menu.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SpringHoverButton(
      key: const Key('bar-template'),
      onTap: onTap,
      child: SizedBox(
        width: _kChipWidth,
        height: _kBarButtonHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              const Icon(LucideIcons.layoutTemplate,
                  size: 22, color: Color(0xFFE9E9EC)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(selectedName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    textAlign: TextAlign.left,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFE9E9EC))),
              ),
              const SizedBox(width: 2),
              const Icon(LucideIcons.chevronDown,
                  size: 13, color: Color(0xFF7E7E86)),
            ],
          ),
        ),
      ),
    );
  }
}
