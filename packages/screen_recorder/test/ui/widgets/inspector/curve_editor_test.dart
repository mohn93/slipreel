import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
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
  Future<void> rename(String id, String newName) async {
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i].id == id) {
        _entries[i] = NamedCurve(id: id, name: newName, curve: _entries[i].curve);
      }
    }
  }
  @override
  Future<void> delete(String id) async {
    _entries.removeWhere((e) => e.id == id);
  }
}

void main() {
  testWidgets('numeric input edits flow back to onChanged on submit',
      (tester) async {
    CubicBezierCurve? captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          curve: const CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4),
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
    CubicBezierCurve? captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          curve: const CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4),
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

  testWidgets('clicking a built-in chip overwrites the curve', (tester) async {
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
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('curveEditor.chip.ease')));
    await tester.pump();

    expect(captured, BuiltInCurves.byId('ease')!.curve);
  });

  testWidgets('Save to library persists then shows the new chip',
      (tester) async {
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
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('curveEditor.saveButton')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('curveEditor.saveNameField')), 'snap-back');
    await tester.tap(find.byKey(const ValueKey('curveEditor.saveConfirm')));
    await tester.pumpAndSettle();

    expect(lib.list().then((l) => l.first.name), completion('snap-back'));
    expect(find.byKey(const ValueKey('curveEditor.chip.0')), findsOneWidget);
  });

  testWidgets('hides duration slider when showDurationSlider=false',
      (tester) async {
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
