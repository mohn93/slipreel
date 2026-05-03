import 'package:screen_recorder/rendering/animation_curve.dart';

/// Identifies a curve in chip rows and editor state. The same record
/// shape is used for built-ins and for user-saved entries.
class NamedCurve {
  const NamedCurve({
    required this.id,
    required this.name,
    required this.curve,
  });
  final String id;
  final String name;
  final CubicBezierCurve curve;
}

/// CSS-standard easings rendered first in the editor's chip row.
/// They never appear in the on-disk library file.
class BuiltInCurves {
  static const List<NamedCurve> all = [
    NamedCurve(
      id: 'linear',
      name: 'Linear',
      curve: CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease',
      name: 'Ease',
      curve: CubicBezierCurve(x1: 0.25, y1: 0.10, x2: 0.25, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease-in',
      name: 'Ease in',
      curve: CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 1.0, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease-out',
      name: 'Ease out',
      curve: CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease-in-out',
      name: 'Ease in-out',
      curve: CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0),
    ),
  ];

  static NamedCurve? byId(String id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }
}
