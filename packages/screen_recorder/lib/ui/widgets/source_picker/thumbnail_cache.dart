import 'dart:typed_data';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class ThumbnailCache {
  final Map<String, Uint8List> _store = {};

  String _key(RecordingSource kind, String id) => '${kind.name}:$id';

  Uint8List? get(RecordingSource kind, String id) => _store[_key(kind, id)];

  void put(RecordingSource kind, String id, Uint8List bytes) {
    _store[_key(kind, id)] = bytes;
  }

  void clear() => _store.clear();
}
