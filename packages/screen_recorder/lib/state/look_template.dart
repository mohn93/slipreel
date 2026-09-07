import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/state/editor_look.dart';

const String kBuiltinCleanId = 'builtin.clean';
const String kBuiltinShowcaseId = 'builtin.showcase';
const String kBuiltinMinimalId = 'builtin.minimal';

/// A named, reusable editor look. Built-ins are code-defined and never
/// written to disk; user templates persist via LookTemplateStore.
class LookTemplate {
  const LookTemplate({
    required this.id,
    required this.name,
    required this.builtIn,
    required this.look,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final bool builtIn;
  final EditorLook look;
  final DateTime updatedAt;

  LookTemplate copyWith({String? name, EditorLook? look, DateTime? updatedAt}) =>
      LookTemplate(
        id: id,
        name: name ?? this.name,
        builtIn: builtIn,
        look: look ?? this.look,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'look': look.toJson(),
      };

  /// Parses a user template. Throws if required keys are missing/malformed;
  /// the store catches per-entry so one bad row does not sink the file.
  factory LookTemplate.fromJson(Map<String, dynamic> json) => LookTemplate(
        id: json['id'] as String,
        name: json['name'] as String,
        builtIn: false,
        look: EditorLook.fromJson(
          (json['look'] as Map).cast<String, dynamic>(),
        ),
        updatedAt:
            DateTime.tryParse(json['updatedAt'] as String? ?? '')?.toUtc() ??
                DateTime.now().toUtc(),
      );

  @override
  bool operator ==(Object other) =>
      other is LookTemplate &&
      other.id == id &&
      other.name == name &&
      other.builtIn == builtIn &&
      other.look == look &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(id, name, builtIn, look, updatedAt);
}

/// The three read-only starter templates, in display order.
List<LookTemplate> builtinLookTemplates() {
  final epoch = DateTime.utc(2026, 1, 1);
  LookTemplate b(String id, String name, WindowFrame frame, ZoomLook zoom) =>
      LookTemplate(
        id: id,
        name: name,
        builtIn: true,
        look: EditorLook.defaults()
            .copyWith(windowFrame: frame, defaultZoomLook: zoom),
        updatedAt: epoch,
      );
  return [
    b(kBuiltinCleanId, 'Clean', WindowFrame.rounded(), ZoomLook.classic),
    b(kBuiltinShowcaseId, 'Showcase', WindowFrame.modern(), ZoomLook.showcase),
    b(kBuiltinMinimalId, 'Minimal', WindowFrame.minimal(), ZoomLook.flat),
  ];
}
