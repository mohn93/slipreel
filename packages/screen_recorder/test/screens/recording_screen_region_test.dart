import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screen_recorder/ui/screens/recording_screen.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform with MockPlatformInterfaceMixin {
  _FakePlatform({this.regionResult, this.screens = const []});
  final RegionSelection? regionResult;
  final List<ScreenInfo> screens;

  @override
  Future<SourceList> listSources({bool strictFilter = true}) async =>
      SourceList(screens: screens);

  @override
  Future<Uint8List?> captureThumbnail(String id, RecordingSource kind,
          {int maxDimension = 480}) async =>
      null;

  @override
  Future<RegionSelection?> selectRegion() async => regionResult;
}

void main() {
  Widget wrap(_FakePlatform p) {
    ScreenRecorderPlatform.instance = p;
    return const ProviderScope(child: MaterialApp(home: RecordingScreen()));
  }

  testWidgets('shows Region segment', (tester) async {
    await tester.pumpWidget(wrap(_FakePlatform()));
    await tester.pumpAndSettle();
    expect(find.text('Region'), findsOneWidget);
  });

  testWidgets('Region tab empty state shows Draw a region button', (tester) async {
    await tester.pumpWidget(wrap(_FakePlatform()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region'));
    await tester.pumpAndSettle();
    expect(find.text('Draw a region'), findsOneWidget);
  });

  testWidgets('selectRegion success shows recap and enables Record', (tester) async {
    final p = _FakePlatform(
      regionResult: const RegionSelection(
          displayId: '1', x: 0, y: 0, widthPx: 1280, heightPx: 720),
      screens: [
        const ScreenInfo(id: '1', name: 'Built-in', width: 2560, height: 1600),
      ],
    );
    await tester.pumpWidget(wrap(p));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw a region'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1280 × 720'), findsOneWidget);
    expect(find.text('Redraw'), findsOneWidget);

    // Confirm the Record button is actually enabled.
    final recordBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Record'),
    );
    expect(recordBtn.onPressed, isNotNull);
  });

  testWidgets('selectRegion null leaves empty state', (tester) async {
    final p = _FakePlatform(regionResult: null);
    await tester.pumpWidget(wrap(p));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw a region'));
    await tester.pumpAndSettle();
    expect(find.text('Draw a region'), findsOneWidget);
    expect(find.textContaining('×'), findsNothing);
  });

  testWidgets('switching tabs clears selectedRegion', (tester) async {
    final p = _FakePlatform(
      regionResult: const RegionSelection(
          displayId: '1', x: 0, y: 0, widthPx: 1280, heightPx: 720),
    );
    await tester.pumpWidget(wrap(p));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw a region'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1280 × 720'), findsOneWidget);
    await tester.tap(find.text('Windows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region'));
    await tester.pumpAndSettle();
    expect(find.text('Draw a region'), findsOneWidget);
    expect(find.textContaining('1280 × 720'), findsNothing);
  });
}
