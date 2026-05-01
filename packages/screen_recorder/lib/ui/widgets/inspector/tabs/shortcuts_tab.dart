import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

class ShortcutsTab extends StatelessWidget {
  const ShortcutsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const InspectorPlaceholder(
      icon: Icons.keyboard_command_key,
      title: 'Keystrokes',
      body: 'On-screen keyboard-shortcut overlay during playback '
          'will appear here. Captured key events from recording '
          'time will drive the display.',
    );
  }
}
