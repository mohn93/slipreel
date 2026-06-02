import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/slice_editor.dart';
import 'package:screen_recorder/ui/screens/playback_screen.dart';

EditorProjectState _stateWith(List<ClipSlice> clips) {
  final base = EditorProjectState.defaults();
  return base.copyWith(timeline: base.timeline.copyWith(clips: clips));
}

Widget _harness({
  required List<ClipSlice> clips,
  required int sliceIndex,
}) {
  return ProviderScope(
    overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: _stateWith(clips)),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SliceEditor(sliceIndex: sliceIndex, onClose: () {}),
      ),
    ),
  );
}

void main() {
  group('SliceEditor header subtitle trimmed-Ns suffix', () {
    testWidgets('untrimmed slice shows only bounds (no trimmed suffix)', (tester) async {
      await tester.pumpWidget(_harness(
        clips: [
          ClipSlice(
            cutStart: Duration.zero,
            cutEnd: const Duration(seconds: 12),
          ),
        ],
        sliceIndex: 0,
      ));
      expect(find.textContaining('trimmed'), findsNothing);
    });

    testWidgets('trimmed slice shows "trimmed Ns" suffix', (tester) async {
      await tester.pumpWidget(_harness(
        clips: [
          ClipSlice(
            cutStart: Duration.zero,
            cutEnd: const Duration(seconds: 12),
            trimStart: const Duration(seconds: 1),
            trimEnd: const Duration(seconds: 10),
          ),
        ],
        sliceIndex: 0,
      ));
      expect(find.textContaining('trimmed 3'), findsOneWidget);
    });
  });

  group('SliceEditor sliceIndex routing', () {
    testWidgets('renders the slice at the given index, not always [0]', (tester) async {
      await tester.pumpWidget(_harness(
        clips: [
          ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 5)),
          ClipSlice(
            cutStart: const Duration(seconds: 5),
            cutEnd: const Duration(seconds: 12),
            playbackSpeed: 2.5,
          ),
        ],
        sliceIndex: 1,
      ));
      // The header subtitle includes the slice's trim bounds — slice 1 is 0:05–0:12.
      expect(find.textContaining('0:05'), findsOneWidget);
      expect(find.textContaining('0:12'), findsOneWidget);
    });

    testWidgets('out-of-range sliceIndex renders the missing-slice fallback', (tester) async {
      await tester.pumpWidget(_harness(
        clips: [
          ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 5)),
        ],
        sliceIndex: 99,
      ));
      expect(find.text('No slice selected'), findsOneWidget);
    });
  });

  group('selection index decrement on removal', () {
    test('idx == removed -> null', () {
      expect(decrementSelectionOnRemoval(selected: 2, removed: 2), null);
    });
    test('idx > removed -> idx - 1', () {
      expect(decrementSelectionOnRemoval(selected: 3, removed: 1), 2);
    });
    test('idx < removed -> unchanged', () {
      expect(decrementSelectionOnRemoval(selected: 1, removed: 2), 1);
    });
    test('null selected -> null', () {
      expect(decrementSelectionOnRemoval(selected: null, removed: 1), null);
    });
  });
}
