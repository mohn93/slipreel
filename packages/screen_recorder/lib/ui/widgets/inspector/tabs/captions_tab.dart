import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

class CaptionsTab extends StatelessWidget {
  const CaptionsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const InspectorPlaceholder(
      icon: Icons.closed_caption_off,
      title: 'Captions',
      body: 'Auto-generated and manual captions will live here. '
          'Speech-to-text transcription is planned for a future '
          'release.',
    );
  }
}
