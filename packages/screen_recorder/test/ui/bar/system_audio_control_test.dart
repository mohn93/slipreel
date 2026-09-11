import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  Widget host(SystemAudioConfig? cfg) => MaterialApp(
    home: Scaffold(
      body: SystemAudioControlForTest(systemAudio: cfg, onTap: () {}),
    ),
  );

  testWidgets('off exposes "System audio off"', (t) async {
    await t.pumpWidget(host(null));
    expect(find.bySemanticsLabel('System audio off'), findsOneWidget);
  });

  testWidgets('all apps shows "System audio"', (t) async {
    await t.pumpWidget(
      host(const SystemAudioConfig(mode: SystemAudioMode.allApps)),
    );
    expect(find.bySemanticsLabel('System audio'), findsOneWidget);
  });

  testWidgets('selected apps shows the count', (t) async {
    await t.pumpWidget(
      host(
        const SystemAudioConfig(
          mode: SystemAudioMode.selectedApps,
          bundleIds: ['a', 'b', 'c'],
        ),
      ),
    );
    expect(find.bySemanticsLabel('3 apps'), findsOneWidget);
  });
}
