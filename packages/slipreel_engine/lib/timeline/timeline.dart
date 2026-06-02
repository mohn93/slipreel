import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/clip_slice.dart';

/// One lane of [ZoomRegion]s on the [Timeline].
///
/// Today the editor only renders the first zoom track — multi-track
/// is scaffolded but not yet exposed through the inspector. Wrapping
/// the region list in a track lets us add per-track properties
/// (mute, lock, color label) later without re-shaping the persisted
/// state again.
class ZoomTrack {
  const ZoomTrack({this.regions = const <ZoomRegion>[]});

  final List<ZoomRegion> regions;

  ZoomTrack copyWith({List<ZoomRegion>? regions}) =>
      ZoomTrack(regions: regions ?? this.regions);

  Map<String, dynamic> toJson() => {
        'regions': regions.map((r) => r.toJson()).toList(),
      };

  factory ZoomTrack.fromJson(Map<String, dynamic> json) {
    final raw = json['regions'];
    final regions = <ZoomRegion>[];
    if (raw is List) {
      for (final r in raw) {
        if (r is Map<String, dynamic>) {
          regions.add(ZoomRegion.fromJson(r));
        }
      }
    }
    return ZoomTrack(regions: List.unmodifiable(regions));
  }
}

/// Container for every track on a recording — zoom regions today,
/// caption tracks, audio tracks, and multi-clip splits later.
///
/// Replaces the flat `EditorProjectState.zoomRegions` field. Future
/// fields will append to this class:
///
///   - `clips: List<Clip>` for trim+stitch multi-clip support
///   - `captionTracks: List<CaptionTrack>` for burned-in subtitles
///   - `audioTracks: List<AudioTrack>` for narration + background music
///
/// We deliberately don't introduce empty placeholder lists for those
/// today — they have no consumers, so they'd be cargo. The schema
/// migration chain will fill them in (with empty defaults) when the
/// fields land.
class Timeline {
  const Timeline({
    this.zoomTracks = const <ZoomTrack>[],
    this.clips = const <ClipSlice>[],
  });

  /// Sensible blank slate: one empty zoom track, no clips (the
  /// controller seeds a single slice once it knows the video duration).
  factory Timeline.defaults() => const Timeline(
        zoomTracks: [ZoomTrack()],
      );

  final List<ZoomTrack> zoomTracks;
  final List<ClipSlice> clips;

  /// Convenience read accessor for code that hasn't yet been updated
  /// to pick a specific zoom track. Returns the regions on the first
  /// track, or an empty list if no tracks exist. The editor renders
  /// against this today.
  List<ZoomRegion> get activeZoomRegions =>
      zoomTracks.isEmpty ? const <ZoomRegion>[] : zoomTracks.first.regions;

  Timeline copyWith({
    List<ZoomTrack>? zoomTracks,
    List<ClipSlice>? clips,
  }) =>
      Timeline(
        zoomTracks: zoomTracks ?? this.zoomTracks,
        clips: clips ?? this.clips,
      );

  Map<String, dynamic> toJson() => {
        'zoomTracks': zoomTracks.map((t) => t.toJson()).toList(),
        'clips': clips.map((c) => c.toJson()).toList(),
      };

  factory Timeline.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['zoomTracks'];
    final tracks = <ZoomTrack>[];
    if (rawTracks is List) {
      for (final t in rawTracks) {
        if (t is Map<String, dynamic>) {
          tracks.add(ZoomTrack.fromJson(t));
        }
      }
    }
    final rawClips = json['clips'];
    final clips = <ClipSlice>[];
    if (rawClips is List) {
      for (final c in rawClips) {
        if (c is Map<String, dynamic>) {
          clips.add(ClipSlice.fromJson(c));
        }
      }
    }
    return Timeline(
      zoomTracks: List.unmodifiable(tracks),
      clips: List.unmodifiable(clips),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Timeline &&
          _listEq(other.zoomTracks, zoomTracks) &&
          _listEq(other.clips, clips);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(zoomTracks),
        Object.hashAll(clips),
      );
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
