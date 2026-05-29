// packages/screen_recorder/test/state/recovery_service_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recovery_service.dart';
import 'package:screen_recorder/state/session_marker.dart';
import 'package:slipreel_engine/models/recording_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SpyStore implements SessionMarkerStore {
  @override
  String get path => '';
  List<SessionMarker> markers;
  final List<String> removed = [];

  _SpyStore(this.markers);

  @override
  Future<List<SessionMarker>> load() async => List.of(markers);

  @override
  Future<void> add(SessionMarker marker) async => markers.add(marker);

  @override
  Future<void> remove(String id) async {
    removed.add(id);
    markers = markers.where((m) => m.id != id).toList(growable: false);
  }
}

ProcessResult _ok(String stdout) => ProcessResult(0, 0, stdout, '');
ProcessResult _err(String stderr) => ProcessResult(0, 1, '', stderr);

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('recovery_svc_');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  SessionMarker mk(String id, {bool createVideo = true, int bytes = 1024}) {
    final videoPath = '${tmp.path}/$id.mp4';
    if (createVideo) {
      File(videoPath).writeAsBytesSync(List.filled(bytes, 0));
    }
    return SessionMarker(
      id: id,
      videoPath: videoPath,
      cursorNdjsonPath: '${tmp.path}/$id.ndjson',
      startedAt: DateTime.utc(2026, 5, 29, 15, 30),
      width: 1920,
      height: 1080,
      fps: 60,
    );
  }

  test('scan filters out markers whose video file is missing', () async {
    final store = _SpyStore([mk('present'), mk('gone', createVideo: false)]);
    final svc = RecoveryService(
        markerStore: store,
        runProcess: (_, __) async => _ok(''));
    final candidates = await svc.scan();
    expect(candidates.map((c) => c.marker.id), ['present']);
    expect(store.removed, ['gone']);
  });

  test('scan filters out zero-byte video files', () async {
    final store = _SpyStore([mk('empty', bytes: 0)]);
    final svc = RecoveryService(
        markerStore: store,
        runProcess: (_, __) async => _ok(''));
    final candidates = await svc.scan();
    expect(candidates, isEmpty);
    expect(store.removed, ['empty']);
  });

  test('recover invokes ffmpeg + removes the marker on success', () async {
    final m = mk('s1', bytes: 4096);
    final store = _SpyStore([m]);
    final calls = <String>[];
    final svc = RecoveryService(
        markerStore: store,
        runProcess: (exe, args) async {
          calls.add('$exe ${args.join(' ')}');
          // Simulate the re-muxed output existing.
          final output = args.last;
          File(output).writeAsBytesSync(List.filled(2048, 1));
          return _ok('Duration: 00:00:30.00');
        });
    final cand = (await svc.scan()).single;
    final history = RecordingHistoryStore();
    final out = await svc.recover(cand, history);
    expect(out, endsWith('.recovered.mp4'));
    expect(calls.first, contains('-c copy'));
    expect(store.removed, ['s1']);
    expect((await history.load()).map((e) => e.videoPath), [out]);
  });

  test('recover returns null + leaves marker when ffmpeg fails', () async {
    final m = mk('s1', bytes: 4096);
    final store = _SpyStore([m]);
    final svc = RecoveryService(
        markerStore: store,
        runProcess: (_, __) async => _err('bad fragment'));
    final cand = (await svc.scan()).single;
    final out = await svc.recover(cand, RecordingHistoryStore());
    expect(out, isNull);
    expect(store.removed, isEmpty); // marker stays, user can try Discard
  });

  test('discard deletes partial files + removes the marker', () async {
    final m = mk('s1', bytes: 4096);
    File(m.cursorNdjsonPath).writeAsStringSync('');
    final store = _SpyStore([m]);
    final svc = RecoveryService(
        markerStore: store,
        runProcess: (_, __) async => _ok(''));
    final cand = (await svc.scan()).single;
    await svc.discard(cand);
    expect(File(m.videoPath).existsSync(), isFalse);
    expect(File(m.cursorNdjsonPath).existsSync(), isFalse);
    expect(store.removed, ['s1']);
  });
}
