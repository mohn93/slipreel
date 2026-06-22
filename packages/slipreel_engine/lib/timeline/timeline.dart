import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomTrack && _listEq(other.regions, regions);

  @override
  int get hashCode => Object.hashAll(regions);
}

/// One lane of [CameraRegion]s on the [Timeline]. Parallels [ZoomTrack];
/// today the editor renders only the first camera track.
class CameraTrack {
  const CameraTrack({this.regions = const <CameraRegion>[]});

  final List<CameraRegion> regions;

  CameraTrack copyWith({List<CameraRegion>? regions}) =>
      CameraTrack(regions: regions ?? this.regions);

  Map<String, dynamic> toJson() => {
        'regions': regions.map((r) => r.toJson()).toList(),
      };

  factory CameraTrack.fromJson(Map<String, dynamic> json) {
    final raw = json['regions'];
    final regions = <CameraRegion>[];
    if (raw is List) {
      for (final r in raw) {
        if (r is Map<String, dynamic>) {
          regions.add(CameraRegion.fromJson(r));
        }
      }
    }
    return CameraTrack(regions: List.unmodifiable(regions));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraTrack && _listEq(other.regions, regions);

  @override
  int get hashCode => Object.hashAll(regions);
}

/// One lane of [CaptionSegment]s on the [Timeline], plus the audio source it
/// was transcribed from (remembered so re-generation preselects it). Parallels
/// [CameraTrack]; today the editor renders only the first caption track.
class CaptionTrack {
  const CaptionTrack({
    this.segments = const <CaptionSegment>[],
    this.source = CaptionAudioSource.mixed,
  });

  final List<CaptionSegment> segments;
  final CaptionAudioSource source;

  CaptionTrack copyWith({
    List<CaptionSegment>? segments,
    CaptionAudioSource? source,
  }) =>
      CaptionTrack(
        segments: segments ?? this.segments,
        source: source ?? this.source,
      );

  Map<String, dynamic> toJson() => {
        'segments': segments.map((s) => s.toJson()).toList(),
        'source': source.name,
      };

  factory CaptionTrack.fromJson(Map<String, dynamic> json) {
    final raw = json['segments'];
    final segments = <CaptionSegment>[];
    if (raw is List) {
      for (final s in raw) {
        if (s is Map<String, dynamic>) {
          segments.add(CaptionSegment.fromJson(s));
        }
      }
    }
    final source = CaptionAudioSource.values
            .where((v) => v.name == json['source'])
            .firstOrNull ??
        CaptionAudioSource.mixed;
    return CaptionTrack(
      segments: List.unmodifiable(segments),
      source: source,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaptionTrack &&
          other.source == source &&
          _listEq(other.segments, segments);

  @override
  int get hashCode => Object.hash(source, Object.hashAll(segments));
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
    this.cameraTracks = const <CameraTrack>[],
    this.captionTracks = const <CaptionTrack>[],
  });

  /// Sensible blank slate: one empty zoom track, no clips (the
  /// controller seeds a single slice once it knows the video duration).
  factory Timeline.defaults() => const Timeline(
        zoomTracks: [ZoomTrack()],
      );

  final List<ZoomTrack> zoomTracks;
  final List<ClipSlice> clips;
  final List<CameraTrack> cameraTracks;
  final List<CaptionTrack> captionTracks;

  /// Convenience read accessor for code that hasn't yet been updated
  /// to pick a specific zoom track. Returns the regions on the first
  /// track, or an empty list if no tracks exist. The editor renders
  /// against this today.
  List<ZoomRegion> get activeZoomRegions =>
      zoomTracks.isEmpty ? const <ZoomRegion>[] : zoomTracks.first.regions;

  /// Regions on the first (active) camera track, or empty when none.
  /// The editor renders against this today.
  List<CameraRegion> get activeCameraRegions =>
      cameraTracks.isEmpty ? const <CameraRegion>[] : cameraTracks.first.regions;

  /// Segments on the first (active) caption track, or empty when none.
  List<CaptionSegment> get activeCaptions => captionTracks.isEmpty
      ? const <CaptionSegment>[]
      : captionTracks.first.segments;

  /// The first (active) caption track, or null when none exists.
  CaptionTrack? get activeCaptionTrack =>
      captionTracks.isEmpty ? null : captionTracks.first;

  Timeline copyWith({
    List<ZoomTrack>? zoomTracks,
    List<ClipSlice>? clips,
    List<CameraTrack>? cameraTracks,
    List<CaptionTrack>? captionTracks,
  }) =>
      Timeline(
        zoomTracks: zoomTracks ?? this.zoomTracks,
        clips: clips ?? this.clips,
        cameraTracks: cameraTracks ?? this.cameraTracks,
        captionTracks: captionTracks ?? this.captionTracks,
      );

  Map<String, dynamic> toJson() => {
        'zoomTracks': zoomTracks.map((t) => t.toJson()).toList(),
        'clips': clips.map((c) => c.toJson()).toList(),
        'cameraTracks': cameraTracks.map((t) => t.toJson()).toList(),
        'captionTracks': captionTracks.map((t) => t.toJson()).toList(),
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
    final rawCameraTracks = json['cameraTracks'];
    final cameraTracks = <CameraTrack>[];
    if (rawCameraTracks is List) {
      for (final t in rawCameraTracks) {
        if (t is Map<String, dynamic>) {
          cameraTracks.add(CameraTrack.fromJson(t));
        }
      }
    }
    final rawCaptionTracks = json['captionTracks'];
    final captionTracks = <CaptionTrack>[];
    if (rawCaptionTracks is List) {
      for (final t in rawCaptionTracks) {
        if (t is Map<String, dynamic>) {
          captionTracks.add(CaptionTrack.fromJson(t));
        }
      }
    }
    return Timeline(
      zoomTracks: List.unmodifiable(tracks),
      clips: List.unmodifiable(clips),
      cameraTracks: List.unmodifiable(cameraTracks),
      captionTracks: List.unmodifiable(captionTracks),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Timeline &&
          _listEq(other.zoomTracks, zoomTracks) &&
          _listEq(other.clips, clips) &&
          _listEq(other.cameraTracks, cameraTracks) &&
          _listEq(other.captionTracks, captionTracks);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(zoomTracks),
        Object.hashAll(clips),
        Object.hashAll(cameraTracks),
        Object.hashAll(captionTracks),
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
