// packages/screen_recorder/lib/ui/widgets/zoom/device_frame_composition.dart
import 'package:flutter/widgets.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';

/// Lays out a device frame: the source [video] in the screen cutout,
/// the [bezel] PNG on top. Both positioned per [layout]. Used inside
/// PlaybackCanvas's zoom Transform so they scale/pan together.
class DeviceFrameComposition extends StatelessWidget {
  const DeviceFrameComposition({
    super.key,
    required this.layout,
    required this.video,
    required this.bezel,
  });

  final DeviceFrameLayout layout;
  final Widget video;
  final ImageProvider bezel;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fromRect(
          rect: layout.videoRect,
          // Clip the recording to the device screen's rounded corners so its
          // square corners don't show through the bezel PNG's transparent
          // (rounded) cutout. Apple's bezels intentionally leave the cutout
          // corners transparent and expect the content to be rounded.
          child: ClipRRect(
            borderRadius:
                BorderRadius.circular(layout.videoCornerRadius),
            child: video,
          ),
        ),
        Positioned.fromRect(
          rect: layout.bezelRect,
          child: Image(
            image: bezel,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.high,
          ),
        ),
      ],
    );
  }
}
