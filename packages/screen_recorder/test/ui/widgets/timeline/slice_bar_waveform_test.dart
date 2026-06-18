import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/audio/waveform_peaks.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:screen_recorder/ui/widgets/timeline/slice_bar.dart';
import 'package:screen_recorder/ui/widgets/timeline/waveform_painter.dart';

WaveformPeaks _peaks() => WaveformPeaks(
      bucketsPerSecond: 100,
      peaks: List<double>.generate(1000, (i) => (i % 50) / 50.0), // 10s
      sourceDuration: const Duration(seconds: 10),
    );

Widget _host(SliceBar bar) => MaterialApp(
      home: Scaffold(
        body: Stack(children: [bar]),
      ),
    );

WaveformPainter _painterOf(WidgetTester tester) {
  final cp = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).firstWhere(
        (w) => w.painter is WaveformPainter,
        orElse: () => throw StateError('no WaveformPainter found'),
      );
  return cp.painter as WaveformPainter;
}

void main() {
  final slice = ClipSlice(
    cutStart: Duration.zero,
    cutEnd: const Duration(seconds: 6),
  );

  SliceBar build({
    WaveformPeaks? waveform,
    bool hasMic = true,
    bool hasSystem = false,
    bool micMuted = false,
  }) =>
      SliceBar(
        slice: slice.copyWith(micMuted: micMuted),
        sliceIndex: 0,
        isSelected: false,
        pixelsPerSecond: 50, // 6s * 50 = 300px wide
        editedStart: Duration.zero,
        waveform: waveform,
        hasMic: hasMic,
        hasSystem: hasSystem,
        onSelectionToggle: (_) {},
        onTrimStartChanged: (_) {},
        onTrimEndChanged: (_) {},
      );

  testWidgets('paints empty samples when peaks are absent', (tester) async {
    await tester.pumpWidget(_host(build(waveform: null)));
    expect(_painterOf(tester).samples, isEmpty);
  });

  testWidgets('renders a non-empty WaveformPainter when peaks exist',
      (tester) async {
    await tester.pumpWidget(_host(build(waveform: _peaks())));
    await tester.pump(const Duration(milliseconds: 250)); // fade-in
    final painter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byKey(const ValueKey('slice-bar-waveform')),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter as WaveformPainter;
    expect(painter.samples, isNotEmpty);
  });

  testWidgets('muted slice dims the waveform layer to a low opacity',
      (tester) async {
    await tester.pumpWidget(_host(build(waveform: _peaks(), micMuted: true)));
    await tester.pump(const Duration(milliseconds: 250));
    final waveformOpacity = tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byKey(const ValueKey('slice-bar-waveform')),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(waveformOpacity, lessThan(0.5));
  });
}
