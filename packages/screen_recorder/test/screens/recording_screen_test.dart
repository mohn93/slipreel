import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder/ui/screens/recording_screen.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform with MockPlatformInterfaceMixin {
  _FakePlatform({
    this.windows = const [],
    this.screens = const [],
    this.permissionDenied = false,
    bool? lastStrictFilter,
  }) : _lastStrictFilter = lastStrictFilter;

  final List<WindowInfo> windows;
  final List<ScreenInfo> screens;
  final bool permissionDenied;
  bool? _lastStrictFilter;
  bool? get lastStrictFilter => _lastStrictFilter;

  @override
  Future<SourceList> listSources({bool strictFilter = true}) async {
    _lastStrictFilter = strictFilter;
    if (permissionDenied) {
      throw PlatformException(
          code: 'DISCOVERY_FAILED',
          message: 'Screen recording permission denied');
    }
    return SourceList(windows: windows, screens: screens);
  }

  @override
  Future<Uint8List?> captureThumbnail(String id, RecordingSource kind,
      {int maxDimension = 480}) async => null;
}

void main() {
  Widget wrap(_FakePlatform platform) {
    ScreenRecorderPlatform.instance = platform;
    return const ProviderScope(child: MaterialApp(home: RecordingScreen()));
  }

  testWidgets('shows Windows and Screens segments', (tester) async {
    await tester.pumpWidget(wrap(_FakePlatform()));
    await tester.pumpAndSettle();
    expect(find.text('Windows'), findsOneWidget);
    expect(find.text('Screens'), findsOneWidget);
  });

  testWidgets('Windows tab shows tiles from listSources', (tester) async {
    final platform = _FakePlatform(windows: [
      const WindowInfo(
          id: '1', title: 'Doc', ownerName: 'App',
          x: 0, y: 0, width: 800, height: 600),
    ]);
    await tester.pumpWidget(wrap(platform));
    await tester.pumpAndSettle();
    expect(find.text('Doc'), findsOneWidget);
    expect(find.text('App'), findsOneWidget);
  });

  testWidgets('switching to Screens clears window selection', (tester) async {
    final platform = _FakePlatform(
      windows: [
        const WindowInfo(
            id: '1', title: 'Doc', ownerName: 'App',
            x: 0, y: 0, width: 800, height: 600),
      ],
      screens: [
        const ScreenInfo(
            id: '100', name: 'Built-in',
            width: 2560, height: 1600, isPrimary: true),
      ],
    );
    await tester.pumpWidget(wrap(platform));
    await tester.pumpAndSettle();
    // Select a window
    await tester.tap(find.text('Doc'));
    await tester.pumpAndSettle();
    // Switch tab
    await tester.tap(find.text('Screens'));
    await tester.pumpAndSettle();
    // Bottom bar should not show the window title anymore
    expect(find.text('Doc'), findsNothing);
  });

  testWidgets('empty Windows tab shows empty-state message', (tester) async {
    await tester.pumpWidget(wrap(_FakePlatform()));
    await tester.pumpAndSettle();
    expect(find.textContaining('No app windows'), findsOneWidget);
  });

  testWidgets('permission error shows Open System Settings button', (tester) async {
    await tester.pumpWidget(wrap(_FakePlatform(permissionDenied: true)));
    await tester.pumpAndSettle();
    expect(find.text('Open System Settings'), findsOneWidget);
  });

  testWidgets('Show all toggle calls listSources with strictFilter false', (tester) async {
    final platform = _FakePlatform();
    await tester.pumpWidget(wrap(platform));
    await tester.pumpAndSettle();
    expect(platform.lastStrictFilter, true);
    await tester.tap(find.byTooltip('Show all windows'));
    await tester.pumpAndSettle();
    expect(platform.lastStrictFilter, false);
  });
}
