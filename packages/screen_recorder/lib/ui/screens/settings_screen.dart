import 'package:flutter/material.dart';
import 'package:slipreel_engine/models/window_frame.dart';

/// Settings screen for customizing window frame appearance.
///
/// Pure value+callback widget — the caller owns the current
/// [WindowFrame] and persists changes via [onChanged]. This keeps the
/// screen reusable across contexts (playback editor writes to the
/// editor notifier; the recording bar uses it as a read-only preview
/// without persistence).
///
/// Provides controls for:
/// - Selecting frame templates
/// - Adjusting padding
/// - Adjusting corner radius
/// - Adjusting shadow blur
/// - Selecting background colors
class SettingsScreen extends StatefulWidget {
  final WindowFrame frame;
  final ValueChanged<WindowFrame> onChanged;

  const SettingsScreen({
    super.key,
    required this.frame,
    required this.onChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late WindowFrame _frame = widget.frame;

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Adopt updates pushed in from outside (e.g. the editor notifier
    // publishing a new frame while this screen is mounted).
    if (oldWidget.frame != widget.frame && widget.frame != _frame) {
      _frame = widget.frame;
    }
  }

  void _commit(WindowFrame next) {
    if (next == _frame) return;
    setState(() => _frame = next);
    widget.onChanged(next);
  }

  void _selectTemplate(String name) {
    final template = WindowFrame.templates.firstWhere(
      (f) => f.name == name,
      orElse: () => WindowFrame.none(),
    );
    _commit(template);
  }

  void _updatePadding(double padding) => _commit(
        _frame.copyWith(padding: EdgeInsets.all(padding), name: 'Custom'),
      );

  void _updateCornerRadius(double radius) =>
      _commit(_frame.copyWith(cornerRadius: radius, name: 'Custom'));

  void _updateShadowBlur(double blur) =>
      _commit(_frame.copyWith(shadowBlur: blur, name: 'Custom'));

  void _updateBackgroundColor(Color? color) =>
      _commit(_frame.copyWith(backgroundColor: color, name: 'Custom'));

  @override
  Widget build(BuildContext context) {
    final frame = _frame;

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
              divisions: 20,
              onChanged: _updatePadding,
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
              divisions: 16,
              onChanged: _updateCornerRadius,
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
              divisions: 16,
              onChanged: _updateShadowBlur,
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
              _selectTemplate(template.name);
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
    required int? divisions,
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
            divisions: divisions,
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
            _updateBackgroundColor(color);
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
