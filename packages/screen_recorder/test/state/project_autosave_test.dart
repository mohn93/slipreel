import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/project_autosave.dart';

void main() {
  test('failed save remains dirty and retry writes the newest edits', () async {
    var fail = true;
    final writes = <int>[];
    final save = ProjectAutosave<int>(
      write: (value) async {
        if (fail) throw StateError('disk unavailable');
        writes.add(value);
      },
    );
    save.schedule(1);
    expect(await save.flush(), isFalse);
    expect(save.status, ProjectSaveStatus.failed);
    expect(save.dirty, isTrue);
    save.schedule(2);
    fail = false;
    expect(await save.flush(), isTrue);
    expect(writes, [2]);
    expect(save.status, ProjectSaveStatus.saved);
    save.dispose();
  });

  test('exit awaits an in-flight save and subsequent edits', () async {
    final first = Completer<void>();
    final writes = <int>[];
    final save = ProjectAutosave<int>(
      write: (value) async {
        writes.add(value);
        if (value == 1) await first.future;
      },
    );
    save.schedule(1);
    final pending = save.flush();
    save.schedule(2);
    final registry = PendingProjectSaves();
    registry.add(save.flush);
    var exited = false;
    final exit = registry.flush().then((ok) {
      exited = ok;
    });
    await Future<void>.delayed(Duration.zero);
    expect(exited, isFalse);
    first.complete();
    await pending;
    await exit;
    expect(writes, [1, 2]);
    expect(exited, isTrue);
    save.dispose();
  });

  test(
    'failed project prevents exit without preventing a later retry',
    () async {
      final registry = PendingProjectSaves();
      var writable = false;
      final save = ProjectAutosave<int>(
        write: (_) async {
          if (!writable) throw StateError('read-only');
        },
      );
      save.schedule(1);
      registry.add(save.flush);
      expect(await registry.flush(), isFalse);
      writable = true;
      expect(await registry.flush(), isTrue);
      save.dispose();
    },
  );

  test('abandoned deletion restores edits for the next exit save', () async {
    final writes = <int>[];
    final save = ProjectAutosave<int>(write: (value) async => writes.add(value));
    save.schedule(1);
    await save.discard();
    // The recording could not be deleted; restore the current editor snapshot.
    save.schedule(2);
    expect(save.dirty, isTrue);
    final registry = PendingProjectSaves()..add(save.flush);
    expect(await registry.flush(), isTrue);
    expect(writes, [2]);
    save.dispose();
  });

  test(
    'explicit discard drains existing write and cancels deferred save',
    () async {
      final writes = <int>[];
      final save = ProjectAutosave<int>(
        write: (value) async => writes.add(value),
      );
      save.schedule(1);
      await save.discard();
      expect(await save.flush(), isTrue);
      expect(writes, isEmpty);
      save.dispose();
    },
  );
}
