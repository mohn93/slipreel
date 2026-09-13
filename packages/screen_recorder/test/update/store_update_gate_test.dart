import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/distribution/distribution_channel.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder/state/window_mode.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';
import 'package:screen_recorder/update/store_update_controller.dart';
import 'package:screen_recorder/update/store_update_gate.dart';
import 'package:screen_recorder/update/store_update_policy.dart';
import 'package:screen_recorder/update/required_update.dart';

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

class _Updates extends StoreUpdateController {
  void publish(bool required) => state = StoreUpdatePolicy(
    build: 10108,
    version: '1.1.0',
    required: required,
  );
  @override
  Future<void> refresh() async {}
}

void main() {
  testWidgets(
    'Store policy defers during recording and export, then blocks until cleared',
    (tester) async {
      final updates = _Updates()..publish(true);
      final recording = _Recording()..setStatus(RecordingStatus.recording);
      final container = ProviderContainer(
        overrides: [
          storeUpdateProvider.overrideWith((ref) => updates),
          recordingControllerProvider.overrideWith((ref) => recording),
          windowChromeProvider.overrideWithValue(_Chrome()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (_, child) => StoreUpdateGate(child: child!),
            home: const Scaffold(body: Text('Local work')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Update Slipreel to continue'), findsNothing);
      container.read(activeUpdateExportsProvider.notifier).state = 1;
      recording.setStatus(RecordingStatus.completed);
      await tester.pumpAndSettle();
      expect(find.text('Update Slipreel to continue'), findsNothing);
      container.read(activeUpdateExportsProvider.notifier).state = 0;
      await tester.pumpAndSettle();
      expect(find.text('Update Slipreel to continue'), findsOneWidget);
      expect(find.text('Later'), findsNothing);
      expect(container.read(requiredUpdateProvider), isNotNull);
      updates.dismiss();
      expect(container.read(requiredUpdateProvider), isNotNull);
      updates.publish(false);
      await tester.pumpAndSettle();
      expect(find.text('Later'), findsOneWidget);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.text('A new Slipreel is ready'), findsNothing);
      expect(container.read(requiredUpdateProvider), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    skip: !DistributionChannel.isAppStore,
  );
}
