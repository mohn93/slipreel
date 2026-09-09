import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum ProjectSaveStatus { saved, pending, saving, failed }

/// Keeps the newest dirty snapshot until a write succeeds. All callers share
/// one write loop, so exit/retry cannot report success for an older snapshot.
class ProjectAutosave<T> extends ChangeNotifier {
  ProjectAutosave({
    required this.write,
    this.debounce = const Duration(milliseconds: 500),
  });
  final Future<void> Function(T) write;
  final Duration debounce;
  ProjectSaveStatus status = ProjectSaveStatus.saved;
  T? _pending;
  int _revision = 0, _savedRevision = 0;
  Timer? _timer;
  Future<bool>? _flight;
  bool _disposed = false;
  bool get dirty => _revision != _savedRevision;

  void _status(ProjectSaveStatus next) {
    status = next;
    if (!_disposed) notifyListeners();
  }

  void schedule(T value) {
    if (_disposed) return;
    _pending = value;
    _revision++;
    // Leave the failed indicator visible until an explicit retry succeeds.
    if (status != ProjectSaveStatus.failed) _status(ProjectSaveStatus.pending);
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _timer = null;
      unawaited(flush());
    });
  }

  Future<bool> flush() {
    _timer?.cancel();
    _timer = null;
    return _flight ??= _save().whenComplete(() => _flight = null);
  }

  Future<bool> _save() async {
    while (dirty) {
      final revision = _revision;
      final snapshot = _pending as T;
      _status(ProjectSaveStatus.saving);
      try {
        await write(snapshot);
      } catch (_) {
        _status(ProjectSaveStatus.failed);
        return false;
      }
      _savedRevision = revision;
    }
    _status(ProjectSaveStatus.saved);
    return true;
  }

  /// Used only after the user explicitly chooses to delete the recording.
  Future<void> discard() async {
    _timer?.cancel();
    _timer = null;
    await _flight;
    _savedRevision = _revision;
    _pending = null;
    _status(ProjectSaveStatus.saved);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Native Cmd+Q and the close button both call this before allowing exit.
class PendingProjectSaves {
  static final instance = PendingProjectSaves();
  static const channel = MethodChannel('slipreel/project-saves');
  final Set<Future<bool> Function()> _saves = {};
  void add(Future<bool> Function() save) => _saves.add(save);
  void remove(Future<bool> Function() save) => _saves.remove(save);
  Future<bool> flush() async {
    for (final save in List.of(_saves)) {
      try {
        if (!await save()) return false;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  void install() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'saveBeforeExit') return flush();
      throw MissingPluginException();
    });
  }
}
