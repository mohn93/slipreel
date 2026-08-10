import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/inspector/contexts/slice_editor.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

EditorProjectState _stateWithOneSlice({
  ClipSlice? slice,
}) {
  return EditorProjectState.defaults().copyWith(
    timeline: Timeline(zoomTracks: []).copyWith(
      clips: [
        slice ??
            ClipSlice(
              cutStart: Duration.zero,
              cutEnd: const Duration(seconds: 10),
            ),
      ],
    ),
  );
}

EditorProjectState _stateWithTwoSlices() {
  return EditorProjectState.defaults().copyWith(
    timeline: Timeline(zoomTracks: []).copyWith(
      clips: [
        ClipSlice(cutStart: Duration.zero, cutEnd: const Duration(seconds: 5)),
        ClipSlice(
          cutStart: const Duration(seconds: 5),
          cutEnd: const Duration(seconds: 10),
        ),
      ],
    ),
  );
}

Widget _host({
  required EditorProjectState initial,
  VoidCallback? onClose,
  int sliceIndex = 0,
}) {
  return ProviderScope(
    overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: initial),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        extensions: const [AppPalette.midnight],
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SliceEditor(
          sliceIndex: sliceIndex,
          onClose: onClose ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders header with formatted slice bounds and speed',
      (tester) async {
    await tester.pumpWidget(_host(initial: _stateWithOneSlice(
      slice: ClipSlice(
        cutStart: Duration.zero,
        cutEnd: const Duration(seconds: 90),
        playbackSpeed: 1.5,
      ),
    )));
    expect(find.textContaining('1:30'), findsOneWidget); // 90s = 1:30
    expect(find.textContaining('1.5'), findsOneWidget);
  });

  testWidgets('Remove slice button is hidden when only one slice',
      (tester) async {
    await tester.pumpWidget(_host(initial: _stateWithOneSlice()));
    expect(find.text('Remove slice'), findsNothing);
  });

  testWidgets('Remove slice button is visible when multiple slices',
      (tester) async {
    await tester.pumpWidget(_host(initial: _stateWithTwoSlices()));
    expect(find.text('Remove slice'), findsOneWidget);
  });

  testWidgets('tapping Remove slice calls removeSlice and onClose',
      (tester) async {
    var closed = false;
    final container = ProviderContainer(overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: _stateWithTwoSlices()),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SliceEditor(
            sliceIndex: 0,
            onClose: () => closed = true,
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Remove slice'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(
      container.read(editorProjectControllerProvider).timeline.clips,
      hasLength(1),
    );
  });

  testWidgets('close button calls onClose without mutating state',
      (tester) async {
    var closed = false;
    final container = ProviderContainer(overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: _stateWithOneSlice()),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SliceEditor(sliceIndex: 0, onClose: () => closed = true),
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(
      container.read(editorProjectControllerProvider).timeline.clips.first
          .playbackSpeed,
      1.0,
    );
  });

  testWidgets('tapping the 2x speed chip calls setSliceSpeed', (tester) async {
    final container = ProviderContainer(overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: _stateWithOneSlice()),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SliceEditor(sliceIndex: 0, onClose: () {}),
        ),
      ),
    ));
    await tester.tap(find.text('2x'));
    await tester.pumpAndSettle();
    expect(
      container.read(editorProjectControllerProvider).timeline.clips.first
          .playbackSpeed,
      2.0,
    );
  });

  testWidgets('toggling Hide cursor calls setSliceHideCursor', (tester) async {
    final container = ProviderContainer(overrides: [
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: _stateWithOneSlice()),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SliceEditor(sliceIndex: 0, onClose: () {}),
        ),
      ),
    ));
    // Target the Hide cursor switch via its label, not positionally —
    // the inspector body section order is UX-driven (Speed, Audio,
    // Cursor, Fades) and the _GainRow widgets also contain Switches.
    final hideCursorRow = find.ancestor(
      of: find.text('Hide cursor'),
      matching: find.byType(Row),
    ).last;
    final hideCursorSwitch = find.descendant(
      of: hideCursorRow,
      matching: find.byType(Switch),
    );
    await tester.tap(hideCursorSwitch);
    await tester.pumpAndSettle();
    expect(
      container.read(editorProjectControllerProvider).timeline.clips.first
          .hideCursor,
      isTrue,
    );
  });

  testWidgets('renders gracefully when sliceIndex is out of range',
      (tester) async {
    await tester.pumpWidget(_host(
      initial: EditorProjectState.defaults(), // empty clips
      sliceIndex: 0,
    ));
    expect(find.textContaining('No slice'), findsOneWidget);
  });

  testWidgets('shows the extended speed presets up to 24x', (tester) async {
    await tester.pumpWidget(_host(initial: _stateWithOneSlice()));
    expect(find.text('4x'), findsOneWidget);
    expect(find.text('8x'), findsOneWidget);
    expect(find.text('16x'), findsOneWidget);
    expect(find.text('24x'), findsOneWidget);
  });

  testWidgets('tapping the 8x chip sets the slice speed to 8x', (tester) async {
    await tester.pumpWidget(_host(initial: _stateWithOneSlice()));
    await tester.tap(find.text('8x'));
    await tester.pumpAndSettle();
    expect(find.text('Final speed: 800%'), findsOneWidget);
  });

  testWidgets('above the threshold the audio rows are replaced by a note',
      (tester) async {
    await tester.pumpWidget(_host(
      initial: _stateWithOneSlice(
        slice: ClipSlice(
          cutStart: Duration.zero,
          cutEnd: const Duration(seconds: 10),
          playbackSpeed: 8.0,
        ),
      ),
    ));
    expect(find.text('Muted above 4x'), findsOneWidget);
    expect(find.text('Mic'), findsNothing);
    expect(find.text('System'), findsNothing);
  });
}
