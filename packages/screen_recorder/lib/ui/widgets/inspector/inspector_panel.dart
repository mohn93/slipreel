import 'package:flutter/material.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/animation_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/audio_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/background_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/camera_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/captions_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/cursor_tab.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/shortcuts_tab.dart';

/// Right-hand inspector for the playback editor.
///
/// Vertical icon rail on the left selects which tab is shown on the
/// right. The selected-tab indicator is a tinted icon plus a small
/// purple dot in the upper-right corner of the icon button (matching
/// Screen Studio's reference).
class InspectorPanel extends StatefulWidget {
  const InspectorPanel({
    super.key,
    required this.frameSettings,
    this.width = 380,
    this.initialTab = InspectorTab.background,
  });

  /// FrameSettings is the only model the inspector currently writes
  /// through to (Background tab → padding/cornerRadius/shadowBlur).
  /// Other tabs hold local state only for now.
  final FrameSettingsProvider frameSettings;
  final double width;
  final InspectorTab initialTab;

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  late InspectorTab _selected = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width,
      decoration: const BoxDecoration(
        color: kInspectorBg,
        border: Border(
          left: BorderSide(color: Color(0xFF14141C), width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Rail(
            selected: _selected,
            onSelect: (t) => setState(() => _selected = t),
          ),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _content() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: switch (_selected) {
        InspectorTab.background =>
          BackgroundTab(frameSettings: widget.frameSettings),
        InspectorTab.cursor => const CursorTab(),
        InspectorTab.camera => const CameraTab(),
        InspectorTab.captions => const CaptionsTab(),
        InspectorTab.audio => const AudioTab(),
        InspectorTab.shortcuts => const ShortcutsTab(),
        InspectorTab.animation => const AnimationTab(),
      },
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.selected, required this.onSelect});
  final InspectorTab selected;
  final ValueChanged<InspectorTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          for (final t in InspectorTab.values) ...[
            _RailButton(
              tab: t,
              isSelected: t == selected,
              onTap: () => onSelect(t),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.tab,
    required this.isSelected,
    required this.onTap,
  });

  final InspectorTab tab;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? kInspectorAccent : Colors.white60;
    return Tooltip(
      message: tab.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isSelected
                ? kInspectorAccent.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(tab.icon, color: color, size: 20),
              if (isSelected)
                const Positioned(
                  top: 6,
                  right: 6,
                  child: _AccentDot(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccentDot extends StatelessWidget {
  const _AccentDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: const BoxDecoration(
        color: kInspectorAccent,
        shape: BoxShape.circle,
      ),
    );
  }
}
