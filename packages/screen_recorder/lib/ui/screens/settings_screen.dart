import 'package:flutter/material.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/models/window_frame.dart';

/// Settings screen for customizing window frame appearance.
///
/// Provides controls for:
/// - Selecting frame templates
/// - Adjusting padding
/// - Adjusting corner radius
/// - Adjusting shadow blur
/// - Selecting background colors
class SettingsScreen extends StatefulWidget {
  final FrameSettingsProvider settingsProvider;

  const SettingsScreen({
    super.key,
    required this.settingsProvider,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    // Listen to provider changes to rebuild UI
    widget.settingsProvider.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    widget.settingsProvider.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.settingsProvider.currentFrame;

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        title: const Text('Frame Settings'),
        backgroundColor: const Color(0xFF2B2B3D),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Template selector
            _buildSectionTitle('Template'),
            const SizedBox(height: 12),
            _buildTemplateSelector(frame),

            const SizedBox(height: 32),

            // Padding slider
            _buildSectionTitle('Padding'),
            const SizedBox(height: 12),
            _buildSlider(
              value: frame.padding.left,
              min: 0,
              max: 100,
              label: '${frame.padding.left.toInt()}px',
              onChanged: (value) {
                widget.settingsProvider.updatePadding(value);
              },
            ),

            const SizedBox(height: 32),

            // Corner radius slider
            _buildSectionTitle('Corner Radius'),
            const SizedBox(height: 12),
            _buildSlider(
              value: frame.cornerRadius,
              min: 0,
              max: 32,
              label: '${frame.cornerRadius.toInt()}px',
              onChanged: (value) {
                widget.settingsProvider.updateCornerRadius(value);
              },
            ),

            const SizedBox(height: 32),

            // Shadow blur slider
            _buildSectionTitle('Shadow Blur'),
            const SizedBox(height: 12),
            _buildSlider(
              value: frame.shadowBlur,
              min: 0,
              max: 80,
              label: '${frame.shadowBlur.toInt()}px',
              onChanged: (value) {
                widget.settingsProvider.updateShadowBlur(value);
              },
            ),

            const SizedBox(height: 32),

            // Color picker
            _buildSectionTitle('Background Color'),
            const SizedBox(height: 12),
            _buildColorPicker(frame),

            const SizedBox(height: 32),

            // Current frame info
            _buildCurrentFrameInfo(frame),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _buildTemplateSelector(WindowFrame currentFrame) {
    final templates = WindowFrame.templates;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: templates.map((template) {
        final isSelected = currentFrame.name == template.name;
        return ChoiceChip(
          label: Text(template.name),
          selected: isSelected,
          onSelected: (selected) {
            if (selected) {
              widget.settingsProvider.selectTemplate(template.name);
            }
          },
          selectedColor: const Color(0xFF6C63FF),
          backgroundColor: const Color(0xFF2B2B3D),
          labelStyle: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSlider({
    required double value,
    required double min,
    required double max,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2B3D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF6C63FF),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${min.toInt()} - ${max.toInt()}',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            activeColor: const Color(0xFF6C63FF),
            inactiveColor: Colors.white24,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildColorPicker(WindowFrame currentFrame) {
    final colors = [
      null, // Transparent
      const Color(0xFFFFFFFF), // White
      const Color(0xFF000000), // Black
      const Color(0xFF6C63FF), // Purple
      const Color(0xFFFF6B6B), // Red
      const Color(0xFF4ECDC4), // Teal
    ];

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: colors.map((color) {
        final isSelected = currentFrame.backgroundColor == color;
        return GestureDetector(
          onTap: () {
            widget.settingsProvider.updateBackgroundColor(color);
          },
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color ?? const Color(0xFF2B2B3D),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? const Color(0xFF6C63FF) : Colors.white24,
                width: isSelected ? 3 : 1,
              ),
            ),
            child: color == null
                ? const Center(
                    child: Icon(
                      Icons.block,
                      color: Colors.white54,
                      size: 24,
                    ),
                  )
                : null,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCurrentFrameInfo(WindowFrame frame) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2B3D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0x4D6C63FF), // 30% opacity
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.info_outline,
                color: Color(0xFF6C63FF),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Current Frame: ${frame.name}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildInfoRow('Padding', '${frame.padding.left.toInt()}px'),
          _buildInfoRow('Corner Radius', '${frame.cornerRadius.toInt()}px'),
          _buildInfoRow('Shadow Blur', '${frame.shadowBlur.toInt()}px'),
          _buildInfoRow(
            'Background',
            frame.backgroundColor == null
                ? 'Transparent'
                : '#${frame.backgroundColor!.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
