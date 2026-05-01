import 'package:flutter/material.dart';

/// Vertical-rail tabs in the playback inspector. Order matches the
/// rail icons reading top-to-bottom.
enum InspectorTab {
  background(icon: Icons.crop_free, label: 'Background'),
  cursor(icon: Icons.mouse, label: 'Cursor'),
  camera(icon: Icons.account_box_outlined, label: 'Camera'),
  captions(icon: Icons.closed_caption_off, label: 'Captions'),
  audio(icon: Icons.volume_up_outlined, label: 'Audio'),
  shortcuts(icon: Icons.keyboard_command_key, label: 'Shortcuts'),
  animation(icon: Icons.timeline, label: 'Animation');

  const InspectorTab({required this.icon, required this.label});

  final IconData icon;
  final String label;
}
