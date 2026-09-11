import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder/state/window_mode.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';
import 'package:screen_recorder/update/required_update.dart';
import 'package:screen_recorder/update/required_update_gate.dart';

class _Chrome implements WindowChrome {
  WindowMode mode = WindowMode.bar;
  @override
  Future<void> setMode(WindowMode value) async => mode = value;
  @override
  Future<String?> showGearMenu() async => null;
  @override
  Future<void> startWindowDrag() async {}
  @override
  Future<void> setBarSize(double width, double height) async {}
}

class _Recording extends RecordingController {
  void setStatus(RecordingStatus status) =>
      state = state.copyWith(status: status);
}

void main() {
  final update = RequiredUpdate(
    build: 1000020,
    version: '1.0.20',
    releaseDate: DateTime.utc(2026),
  );

  testWidgets(
    'navigation cannot cover the required gate; removing policy restores interaction',
    (tester) async {
      final chrome = _Chrome();
      final container = ProviderContainer(
        overrides: [
          entitlementProvider.overrideWithValue(const EntitlementSignedOut()),
          windowChromeProvider.overrideWithValue(chrome),
        ],
      );
      addTearDown(container.dispose);
      final navigator = GlobalKey<NavigatorState>();
      var clicks = 0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigator,
            builder: (_, child) => RequiredUpdateGate(child: child!),
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      );
      container.read(requiredUpdateCandidateProvider.notifier).state = update;
      await tester.pumpAndSettle();
      expect(chrome.mode, WindowMode.panel);
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: TextButton(
                onPressed: () => clicks++,
                child: const Text('Action'),
              ),
            ),
          ),
        ),
      ).ignore();
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsOneWidget);
      await tester.tap(find.text('Action'), warnIfMissed: false);
      await tester.pump();
      expect(clicks, 0);
      container.read(requiredUpdateCandidateProvider.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsNothing);
      expect(chrome.mode, WindowMode.bar);
      await tester.tap(find.text('Action'));
      expect(clicks, 1);
    },
  );

  testWidgets(
    'recording controls remain available until recording and processing finish',
    (tester) async {
      final recording = _Recording()..setStatus(RecordingStatus.recording);
      final container = ProviderContainer(
        overrides: [
          entitlementProvider.overrideWithValue(const EntitlementSignedOut()),
          windowChromeProvider.overrideWithValue(_Chrome()),
          recordingControllerProvider.overrideWith((ref) => recording),
        ],
      );
      addTearDown(container.dispose);
      container.read(requiredUpdateCandidateProvider.notifier).state = update;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (_, child) => RequiredUpdateGate(child: child!),
            home: Scaffold(
              body: TextButton(
                onPressed: () =>
                    recording.setStatus(RecordingStatus.processing),
                child: const Text('Stop'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsNothing);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsNothing);
      recording.setStatus(RecordingStatus.completed);
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsOneWidget);
    },
  );
}
