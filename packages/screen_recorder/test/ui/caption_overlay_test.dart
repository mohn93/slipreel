import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:screen_recorder/ui/widgets/zoom/caption_overlay.dart';

void main() {
  testWidgets('builds a CustomPaint without throwing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 360,
            child: CaptionOverlay(
              position: Duration(milliseconds: 500),
              canvasSize: Size(640, 360),
              segments: [
                CaptionSegment(
                    id: 'a',
                    startMicros: 0,
                    endMicros: 1000000,
                    text: 'hi'),
              ],
              style: CaptionStyle(enabled: true),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
