import 'package:flutter/material.dart';
import 'package:screen_recorder/models/export_settings.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/_export_dialog_theme.dart';

/// Dropdown picker for frame rate. Uses [PopupMenuButton] to avoid a
/// mid-export overlay tear-down if the parent dialog dismisses while
/// the menu is open — Flutter's overlay system handles that gracefully.
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
    assert(
      options.contains(value),
      'value must be in options — currently $value not in $options',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          spacing: 6,
          children: const [
            Icon(
              Icons.speed_outlined,
              size: 14,
              color: kTextPrimary,
            ),
            Text(
              'Frame rate',
              style: TextStyle(
                color: kTextPrimary,
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kSegmentRadius),
          ),
          color: kBgUnselected,
          itemBuilder: (context) => [
            for (final fps in options)
              PopupMenuItem<int>(
                key: ValueKey('fps_option_$fps'),
                value: fps,
                child: Row(
                  spacing: 0,
                  children: [
                    SizedBox(
                      width: 20,
                      child: fps == value
                          ? const Icon(
                              Icons.check,
                              size: 14,
                              color: kAccent,
                            )
                          : null,
                    ),
                    Text(
                      '$fps fps',
                      style: const TextStyle(
                        color: kTextPrimary,
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
            height: kSegmentHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: kBgUnselected,
              borderRadius: BorderRadius.circular(kSegmentRadius),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                Text(
                  '$value fps',
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Icon(
                  Icons.expand_more,
                  size: 16,
                  color: kTextSecondary,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
