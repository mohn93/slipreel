import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

class CameraTab extends StatelessWidget {
  const CameraTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const InspectorPlaceholder(
      icon: Icons.account_box_outlined,
      title: 'Webcam',
      body: 'Pick-in-picture webcam recording is on the roadmap. '
          'You\'ll be able to add a circular or rectangular camera '
          'overlay here.',
    );
  }
}
