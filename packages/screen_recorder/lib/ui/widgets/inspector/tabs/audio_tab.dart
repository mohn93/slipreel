import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Audio tab — background-music presets and "add custom" button.
///
/// Picker is fully interactive locally; nothing is mixed into the
/// recording yet. Add-button is a no-op stub.
class AudioTab extends StatefulWidget {
  const AudioTab({super.key});

  @override
  State<AudioTab> createState() => _AudioTabState();
}

class _AudioTabState extends State<AudioTab> {
  static const _presets = <String>[
    'Lo-Fi',
    'Commercial',
    'Electronic',
    'Instrumental',
    'Sunny Lo-Fi',
    'Lean Groove',
    'Bright Lounge',
  ];
  String? _selected = 'Lo-Fi';

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        const Text(
          'Background audio',
          style: TextStyle(
            color: kInspectorMuted,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in _presets) _presetChip(p),
          ],
        ),
        const InspectorSectionDivider(),
        _addButton(),
      ],
    );
  }

  Widget _presetChip(String label) {
    final isSelected = _selected == label;
    return InkWell(
      onTap: () => setState(() => _selected = label),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? kInspectorAccent : kInspectorBorder,
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _addButton() {
    return InkWell(
      onTap: () {
        // Stub — wire up file-picker + mixing pipeline later.
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: kInspectorAccent.withValues(alpha:0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: kInspectorAccent.withValues(alpha:0.4),
          ),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.library_music_outlined,
                color: kInspectorAccent, size: 18),
            SizedBox(width: 8),
            Text(
              'Add background audio',
              style: TextStyle(
                color: kInspectorAccent,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
