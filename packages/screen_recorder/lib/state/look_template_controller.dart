import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/state/editor_look.dart';

import 'look_template.dart';
import 'look_template_store.dart';

class LookTemplatesState {
  const LookTemplatesState({required this.all, required this.selectedId});
  final List<LookTemplate> all; // built-ins first, then users by name
  final String selectedId;

  LookTemplate get selected => all.firstWhere(
        (t) => t.id == selectedId,
        orElse: () => all.firstWhere((t) => t.id == kBuiltinCleanId),
      );
}

class LookTemplateController extends StateNotifier<LookTemplatesState> {
  LookTemplateController({required this.store, required LookTemplateData initial})
      : _users = List.of(initial.templates),
        super(_compose(initial.templates, initial.selectedId));

  final LookTemplateStore store;
  final List<LookTemplate> _users;
  final Random _rng = Random.secure();

  static LookTemplatesState _compose(List<LookTemplate> users, String selected) {
    final sorted = List.of(users)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final all = [...builtinLookTemplates(), ...sorted];
    final valid = all.any((t) => t.id == selected) ? selected : kBuiltinCleanId;
    return LookTemplatesState(all: all, selectedId: valid);
  }

  void _publish() => state = _compose(_users, state.selectedId);

  Future<void> _persist() =>
      store.saveAll(_users, state.selectedId);

  String _newId() {
    final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void select(String id) {
    if (state.selectedId == id) return;
    state = LookTemplatesState(all: state.all, selectedId: id);
    _persist();
  }

  Future<LookTemplate> saveNew(String name, EditorLook look) async {
    final t = LookTemplate(
      id: _newId(),
      name: name,
      builtIn: false,
      look: look,
      updatedAt: DateTime.now().toUtc(),
    );
    _users.add(t);
    state = LookTemplatesState(
      all: _compose(_users, t.id).all,
      selectedId: t.id,
    );
    await _persist();
    return t;
  }

  Future<void> update(String id, EditorLook look) async {
    final i = _users.indexWhere((t) => t.id == id);
    if (i < 0) return; // built-in or unknown
    _users[i] = _users[i].copyWith(look: look, updatedAt: DateTime.now().toUtc());
    _publish();
    await _persist();
  }

  Future<void> rename(String id, String name) async {
    final i = _users.indexWhere((t) => t.id == id);
    if (i < 0) return;
    _users[i] = _users[i].copyWith(name: name);
    _publish();
    await _persist();
  }

  Future<LookTemplate> duplicate(String id) async {
    final src = state.all.firstWhere((t) => t.id == id);
    return saveNew('${src.name} copy', src.look);
  }

  Future<void> delete(String id) async {
    final before = _users.length;
    _users.removeWhere((t) => t.id == id);
    if (_users.length == before) return; // built-in or unknown
    final nextSelected =
        state.selectedId == id ? kBuiltinCleanId : state.selectedId;
    state = LookTemplatesState(
      all: _compose(_users, nextSelected).all,
      selectedId: nextSelected,
    );
    await _persist();
  }
}

final lookTemplateStoreProvider = Provider<LookTemplateStore>(
  (ref) => throw UnimplementedError('Override lookTemplateStoreProvider in main()'),
);

final lookTemplateControllerProvider =
    StateNotifierProvider<LookTemplateController, LookTemplatesState>(
  (ref) => throw UnimplementedError(
      'Override lookTemplateControllerProvider in main()'),
);
