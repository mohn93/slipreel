import 'package:flutter/material.dart';
import '../../models/export_preset.dart';

/// Dialog for selecting export preset
class ExportDialog extends StatefulWidget {
  const ExportDialog({super.key});

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  ExportPreset? _selectedPreset = ExportPreset.hd1080p30();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2C2C2C),
      title: const Text(
        'Export Video',
        style: TextStyle(color: Colors.white),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: ExportPreset.presets.map((preset) {
            return RadioListTile<ExportPreset>(
              title: Text(
                preset.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                '${preset.width}x${preset.height} @ ${preset.fps}fps',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
              value: preset,
              groupValue: _selectedPreset,
              activeColor: const Color(0xFF4CAF50),
              onChanged: (ExportPreset? value) {
                setState(() {
                  _selectedPreset = value;
                });
              },
            );
          }).toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop(null);
          },
          child: const Text(
            'Cancel',
            style: TextStyle(color: Colors.white70),
          ),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.of(context).pop(_selectedPreset);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF4CAF50),
          ),
          child: const Text(
            'Export',
            style: TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }
}
