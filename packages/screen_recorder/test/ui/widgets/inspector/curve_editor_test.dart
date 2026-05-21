import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';
import 'package:screen_recorder/services/curve_library.dart';
import 'package:screen_recorder/ui/widgets/inspector/curve_editor.dart';

class _FakeLibrary implements CurveLibrary {
  final List<NamedCurve> _entries = [];
  @override
  Future<List<NamedCurve>> list() async => List.of(_entries);
  @override
  Future<NamedCurve> save({required String name, required CubicBezierCurve curve}) async {
    final n = NamedCurve(id: '${_entries.length}', name: name, curve: curve);
    _entries.add(n);
    return n;
  }
  @override
  Future<void> delete(String id) async {
    _entries.removeWhere((e) => e.id == id);
  }
}

/// Tall narrow viewport mirrors the inspector pane the editor lives in.
/// Without it the default 800x600 test surface either pushes the bottom
/// of the editor off-screen (no scroll wrapper anymore) or makes the
/// square graph 800px tall and shoves the chip row out of view.
void _useInspectorViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(280, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Walk a few frames to let _refreshLibrary's microtask resolve and
/// the AnimationController repaint cycles flush. Don't use
/// pumpAndSettle — the demo controller never settles.
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('numeric input edits flow back to onChanged on submit',
      (tester) async {
    _useInspectorViewport(tester);
    CubicBezierCurve? captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          // x2 = 1.0 so the x1 ≤ x2 clamp doesn't constrain this test.
          curve: const CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 1.0, y2: 0.4),
          duration: const Duration(milliseconds: 320),
          durationLabel: 'Duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (c) => captured = c,
          onDurationChanged: (_) {},
          library: _FakeLibrary(),
          showDurationSlider: true,
        ),
      ),
    ));

    final field = find.byKey(const ValueKey('curveEditor.x1Field'));
    await tester.enterText(field, '0.42');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(captured?.x1, closeTo(0.42, 1e-9));
  });

  testWidgets('numeric input clamps x1 to [0, 1]', (tester) async {
    _useInspectorViewport(tester);
    CubicBezierCurve? captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          // x2 = 1.0 so the upper bound of x1 is also 1.0 (clamp(0, x2)).
          curve: const CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 1.0, y2: 0.4),
          duration: const Duration(milliseconds: 320),
          durationLabel: 'Duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (c) => captured = c,
          onDurationChanged: (_) {},
          library: _FakeLibrary(),
          showDurationSlider: true,
        ),
      ),
    ));

    final field = find.byKey(const ValueKey('curveEditor.x1Field'));
    await tester.enterText(field, '1.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(captured?.x1, 1.0);
  });

  testWidgets('x1 may exceed x2 — fold-back curves are allowed', (tester) async {
    tester.view.physicalSize = const Size(280, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    CubicBezierCurve? captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          curve: const CubicBezierCurve(x1: 0.1, y1: 0.0, x2: 0.5, y2: 1.0),
          duration: const Duration(milliseconds: 320),
          durationLabel: 'Duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (c) => captured = c,
          onDurationChanged: (_) {},
          library: _FakeLibrary(),
          showDurationSlider: true,
        ),
      ),
    ));

    // Author a fold-back curve: x1 (0.9) > x2 (0.5). The editor must
    // accept this — authoring non-monotone curves is intentional.
    await tester.enterText(
        find.byKey(const ValueKey('curveEditor.x1Field')), '0.9');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(captured?.x1, closeTo(0.9, 1e-9));
    expect(captured?.x2, closeTo(0.5, 1e-9));
  });

  testWidgets('clicking a built-in chip overwrites the curve', (tester) async {
    _useInspectorViewport(tester);
    CubicBezierCurve? captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          curve: const CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0),
          duration: const Duration(milliseconds: 320),
          durationLabel: 'Duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (c) => captured = c,
          onDurationChanged: (_) {},
          library: _FakeLibrary(),
          showDurationSlider: true,
        ),
      ),
    ));
    await _pumpFrames(tester);

    await tester.tap(find.byKey(const ValueKey('curveEditor.chip.builtin.ease')));
    await tester.pump();

    expect(captured, BuiltInCurves.byId('ease')!.curve);
  });

  testWidgets('Save to library persists then shows the new chip',
      (tester) async {
    _useInspectorViewport(tester);
    final lib = _FakeLibrary();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          curve: const CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.4),
          duration: const Duration(milliseconds: 320),
          durationLabel: 'Duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (_) {},
          onDurationChanged: (_) {},
          library: lib,
          showDurationSlider: true,
        ),
      ),
    ));
    await _pumpFrames(tester);

    await tester.tap(find.byKey(const ValueKey('curveEditor.saveButton')));
    await _pumpFrames(tester);
    await tester.enterText(
        find.byKey(const ValueKey('curveEditor.saveNameField')), 'snap-back');
    await tester.tap(find.byKey(const ValueKey('curveEditor.saveConfirm')));
    await _pumpFrames(tester);

    expect(lib.list().then((l) => l.first.name), completion('snap-back'));
    expect(find.byKey(const ValueKey('curveEditor.chip.saved.0')), findsOneWidget);
  });

  testWidgets('hides duration slider when showDurationSlider=false',
      (tester) async {
    _useInspectorViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          curve: const CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4),
          duration: const Duration(milliseconds: 320),
          durationLabel: 'Duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (_) {},
          onDurationChanged: (_) {},
          library: _FakeLibrary(),
          showDurationSlider: false,
        ),
      ),
    ));

    expect(find.byKey(const ValueKey('curveEditor.durationSlider')),
        findsNothing);
  });
}
