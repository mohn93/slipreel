import 'recording_settings.dart';

/// A source chosen via the native click-to-select overlay.
class PickedSource {
  final RecordingSource kind; // window or screen
  final String id;

  const PickedSource({required this.kind, required this.id});

  factory PickedSource.fromMap(Map<String, dynamic> map) {
    final kind = map['kind'] == 'window'
        ? RecordingSource.window
        : RecordingSource.screen;
    return PickedSource(kind: kind, id: map['id'] as String);
  }
}
