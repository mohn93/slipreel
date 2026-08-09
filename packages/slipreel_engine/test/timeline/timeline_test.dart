import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  group('ZoomTrack', () {
    test('empty by default', () {
      const track = ZoomTrack();
      expect(track.regions, isEmpty);
    });

    test('round-trips through JSON', () {
      final track = ZoomTrack(
        regions: [
          ZoomRegion(
            rect: const Rect.fromLTWH(0.1, 0.2, 0.3, 0.4),
            startTime: const Duration(milliseconds: 500),
            duration: const Duration(seconds: 2),
            zoomLevel: 2.0,
          ),
        ],
      );

      final restored = ZoomTrack.fromJson(track.toJson());

      expect(restored.regions, hasLength(1));
      expect(restored.regions.first.rect, track.regions.first.rect);
      expect(restored.regions.first.zoomLevel, 2.0);
    });

    test('copyWith replaces regions', () {
      const original = ZoomTrack();
      final next = original.copyWith(regions: [
        ZoomRegion(
          rect: const Rect.fromLTWH(0, 0, 1, 1),
          startTime: Duration.zero,
          duration: const Duration(seconds: 1),
          zoomLevel: 1.5,
        ),
      ]);

      expect(original.regions, isEmpty);
      expect(next.regions, hasLength(1));
    });
  });

  group('Timeline', () {
    test('defaults to a single empty zoom track', () {
      final timeline = Timeline.defaults();
      expect(timeline.zoomTracks, hasLength(1));
      expect(timeline.zoomTracks.first.regions, isEmpty);
    });

    test('round-trips through JSON', () {
      final timeline = Timeline(zoomTracks: [
        ZoomTrack(regions: [
          ZoomRegion(
            rect: const Rect.fromLTWH(0, 0, 0.5, 0.5),
            startTime: Duration.zero,
            duration: const Duration(seconds: 1),
            zoomLevel: 1.8,
          ),
        ]),
      ]);

      final restored = Timeline.fromJson(timeline.toJson());

      expect(restored.zoomTracks, hasLength(1));
      expect(restored.zoomTracks.first.regions, hasLength(1));
      expect(restored.zoomTracks.first.regions.first.zoomLevel, 1.8);
    });

    test('copyWith replaces zoom tracks', () {
      final original = Timeline.defaults();
      final next = original.copyWith(zoomTracks: [
        ZoomTrack(regions: [
          ZoomRegion(
            rect: const Rect.fromLTWH(0, 0, 1, 1),
            startTime: Duration.zero,
            duration: const Duration(seconds: 1),
            zoomLevel: 2.0,
          ),
        ]),
      ]);

      expect(original.zoomTracks.first.regions, isEmpty);
      expect(next.zoomTracks.first.regions, hasLength(1));
    });

    test('activeZoomRegions returns first track regions for today', () {
      // Today's editor renders a single zoom track. The convenience
      // getter exists so call sites that haven't been updated to pick
      // a specific track keep working through the refactor.
      final regions = [
        ZoomRegion(
          rect: const Rect.fromLTWH(0, 0, 1, 1),
          startTime: Duration.zero,
          duration: const Duration(seconds: 1),
          zoomLevel: 1.5,
        ),
      ];
      final timeline = Timeline(zoomTracks: [ZoomTrack(regions: regions)]);

      expect(timeline.activeZoomRegions, regions);
    });

    test('activeZoomRegions is empty when no tracks present', () {
      const timeline = Timeline(zoomTracks: []);
      expect(timeline.activeZoomRegions, isEmpty);
    });

    test('fromJson handles missing/empty tracks list defensively', () {
      // Migration writes zoomTracks for v3 sidecars; defending here
      // covers hand-edited / corrupt JSON without crashing the loader.
      final restored = Timeline.fromJson({});
      expect(restored.zoomTracks, isEmpty);
    });
  });

  group('list retention (undo-snapshot corruption)', () {
    // History entries hold EditorProjectState snapshots by reference.
    // If Timeline/track copyWith retained the CALLER'S list, a caller
    // mutating its list after the snapshot silently rewrites history.
    // copyWith must take a defensive unmodifiable copy.
    ZoomRegion region(int startMs) => ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: Duration(milliseconds: startMs),
      duration: const Duration(seconds: 1),
      zoomLevel: 2.0,
    );

    test('Timeline.copyWith does not retain the caller list', () {
      final source = <ZoomTrack>[
        ZoomTrack(regions: [region(0)]),
      ];
      final timeline = const Timeline().copyWith(zoomTracks: source);
      source.clear();
      expect(timeline.zoomTracks, hasLength(1));
      expect(
        () => timeline.zoomTracks.add(const ZoomTrack()),
        throwsUnsupportedError,
      );
    });

    test('ZoomTrack.copyWith does not retain the caller list', () {
      final source = [region(0), region(2000)];
      final track = const ZoomTrack().copyWith(regions: source);
      source.removeLast();
      expect(track.regions, hasLength(2));
      expect(() => track.regions.add(region(4000)), throwsUnsupportedError);
    });
  });
}
