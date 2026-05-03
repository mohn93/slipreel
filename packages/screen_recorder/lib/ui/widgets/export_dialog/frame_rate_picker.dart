import 'package:flutter/material.dart';
import 'package:screen_recorder/models/export_settings.dart';

const Color _kTitleColor = Color(0xFFE8E8EA);
const Color _kIconColor = Color(0xFFE8E8EA);
const Color _kSubtitleColor = Color(0xFF8C8C95);
const Color _kUnselectedFill = Color(0xFF22232C);
const Color _kSelectedBorder = Color(0xFF8B5CF6);

/// Dropdown picker for frame rate. Uses [PopupMenuButton] which integrates
/// cleanly with Flutter's overlay system and avoids manual OverlayEntry
/// lifecycle management.
class FrameRatePicker extends StatelessWidget {
  const FrameRatePicker({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final int value;

  /// The set of available fps values shown in the dropdown. Defaults to
  /// [kFrameRateOptions] for MP4; GIF callers pass a reduced list.
  final List<int> options;

  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: const [
            Icon(
              Icons.speed_outlined,
              size: 14,
              color: _kIconColor,
            ),
            SizedBox(width: 6),
            Text(
              'Frame rate',
              style: TextStyle(
                color: _kTitleColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        PopupMenuButton<int>(
          key: const ValueKey('frame_rate_popup'),
          onSelected: onChanged,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          color: const Color(0xFF22232C),
          itemBuilder: (context) => [
            for (final fps in options)
              PopupMenuItem<int>(
                key: ValueKey('fps_option_$fps'),
                value: fps,
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      child: fps == value
                          ? const Icon(
                              Icons.check,
                              size: 14,
                              color: _kSelectedBorder,
                            )
                          : null,
                    ),
                    Text(
                      '$fps fps',
                      style: const TextStyle(
                        color: _kTitleColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          child: Container(
            key: const ValueKey('frame_rate_closed'),
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _kUnselectedFill,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$value fps',
                  style: const TextStyle(
                    color: _kTitleColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(
                  Icons.expand_more,
                  size: 16,
                  color: _kSubtitleColor,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
