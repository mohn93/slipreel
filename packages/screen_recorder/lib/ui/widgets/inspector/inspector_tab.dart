import 'package:flutter/material.dart';

/// Vertical-rail tabs in the playback inspector. Order matches the
/// rail icons reading top-to-bottom.
enum InspectorTab {
  background(icon: Icons.crop_free, label: 'Background', isEnabled: true),
  device(icon: Icons.devices, label: 'Device', isEnabled: true),
  cursor(icon: Icons.mouse, label: 'Cursor', isEnabled: true),
  camera(icon: Icons.account_box_outlined, label: 'Camera', isEnabled: true),
  captions(icon: Icons.closed_caption_off, label: 'Captions', isEnabled: false),
  audio(icon: Icons.volume_up_outlined, label: 'Audio', isEnabled: true),
  shortcuts(icon: Icons.keyboard_command_key, label: 'Shortcuts', isEnabled: true),
  animation(icon: Icons.timeline, label: 'Animation', isEnabled: true);

  const InspectorTab({
    required this.icon,
    required this.label,
    required this.isEnabled,
  });

  final IconData icon;
  final String label;

  /// When false, the rail renders the tab as non-clickable with a
  /// "coming soon" tooltip. Disabled tabs cannot be selected.
  final bool isEnabled;
}

/// The inspector tabs visible in the rail for the current recording.
/// The [InspectorTab.device] tab only applies to iPhone/iPad captures, so it
/// is hidden for screen recordings. All other tabs are always shown.
List<InspectorTab> visibleInspectorTabs({required bool isDevice}) => [
      for (final t in InspectorTab.values)
        if (t != InspectorTab.device || isDevice) t,
    ];
