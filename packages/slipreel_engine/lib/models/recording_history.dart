import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One row in the recording history list. Persisted to SharedPreferences
/// as JSON. Keep this model small — anything that can be derived from the
/// MP4 itself (duration, codec) belongs in the metadata sidecar, not here.
class RecordingHistoryEntry {
  const RecordingHistoryEntry({
    required this.videoPath,
    required this.recordedAt,
    required this.widthPx,
    required this.heightPx,
    required this.fps,
  });

  final String videoPath;
  final DateTime recordedAt;
  final int widthPx;
  final int heightPx;
  final int fps;

  Map<String, dynamic> toJson() => {
        'videoPath': videoPath,
        'recordedAt': recordedAt.toUtc().toIso8601String(),
        'widthPx': widthPx,
        'heightPx': heightPx,
        'fps': fps,
      };

  factory RecordingHistoryEntry.fromJson(Map<String, dynamic> json) {
    return RecordingHistoryEntry(
      videoPath: json['videoPath'] as String,
      recordedAt: DateTime.parse(json['recordedAt'] as String).toLocal(),
      widthPx: json['widthPx'] as int? ?? 0,
      heightPx: json['heightPx'] as int? ?? 0,
      fps: json['fps'] as int? ?? 30,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecordingHistoryEntry &&
          other.videoPath == videoPath &&
          other.recordedAt == recordedAt &&
          other.widthPx == widthPx &&
          other.heightPx == heightPx &&
          other.fps == fps;

  @override
  int get hashCode =>
      Object.hash(videoPath, recordedAt, widthPx, heightPx, fps);
}

/// Persists the recording history to SharedPreferences as a JSON list.
/// Most-recent first; capped at [maxEntries] to keep prefs small.
class RecordingHistoryStore {
  RecordingHistoryStore({SharedPreferences? prefs})
      : _prefs = prefs,
        _seed = null;

  /// Test-only constructor: seeds the store with a fixed list and never
  /// touches SharedPreferences. Mutations (append/removeByPath) update
  /// the in-memory seed list only.
  RecordingHistoryStore.inMemory(List<RecordingHistoryEntry> entries)
      : _prefs = null,
        _seed = List<RecordingHistoryEntry>.from(entries);

  static const _key = 'recording_history';
  static const int maxEntries = 100;

  SharedPreferences? _prefs;

  /// Non-null only when constructed via [RecordingHistoryStore.inMemory].
  List<RecordingHistoryEntry>? _seed;

  Future<SharedPreferences> _ensure() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Returns the persisted list (most recent first). Silently drops
  /// malformed entries so a single bad row can't lock the user out.
  Future<List<RecordingHistoryEntry>> load() async {
    if (_seed != null) return List<RecordingHistoryEntry>.from(_seed!);
    final prefs = await _ensure();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map<String, dynamic>>()
          .map((m) {
            try {
              return RecordingHistoryEntry.fromJson(m);
            } catch (_) {
              return null;
            }
          })
          .whereType<RecordingHistoryEntry>()
          .toList(growable: false);
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<RecordingHistoryEntry> entries) async {
    if (_seed != null) {
      _seed!
        ..clear()
        ..addAll(entries);
      return;
    }
    final prefs = await _ensure();
    final encoded = jsonEncode(entries.map((e) => e.toJson()).toList());
    await prefs.setString(_key, encoded);
  }

  /// Add [entry] to the front of the history. If an entry with the same
  /// path already exists, it's moved to the front (no duplicates). The
  /// list is truncated to [maxEntries].
  Future<List<RecordingHistoryEntry>> append(
      RecordingHistoryEntry entry) async {
    final current = await load();
    final deduped = current.where((e) => e.videoPath != entry.videoPath).toList()
      ..insert(0, entry);
    final capped = deduped.length > maxEntries
        ? deduped.sublist(0, maxEntries)
        : deduped;
    await _save(capped);
    return capped;
  }

  /// Remove the entry at the given path. No-op if not present.
  Future<List<RecordingHistoryEntry>> removeByPath(String path) async {
    final current = await load();
    final next = current.where((e) => e.videoPath != path).toList();
    if (next.length == current.length) return current;
    await _save(next);
    return next;
  }

  Future<void> clear() async {
    if (_seed != null) {
      _seed!.clear();
      return;
    }
    final prefs = await _ensure();
    await prefs.remove(_key);
  }
}
