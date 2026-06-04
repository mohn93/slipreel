import 'package:flutter/material.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/seam_metrics.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart';

/// Horizontal overlay strip that renders one [CutMarker] per seam
/// between adjacent slices. Sits ABOVE the clip lane, allocating its
/// own [CutMarker.kHitHeight] of vertical space so the markers are
/// inside its render box (and therefore hit-testable).
///
/// The strip is itself sized to [CutMarker.kHitHeight] tall — its
/// parent decides where it sits relative to the clip lane.
class CutMarkerStrip extends StatelessWidget {
  const CutMarkerStrip({
    super.key,
    required this.clips,
    required this.pixelsPerSecond,
    required this.onClearSeamTrims,
    required this.onMergeSeam,
    this.dragging = false,
  });

  final List<ClipSlice> clips;
  final double pixelsPerSecond;
  final ValueChanged<int> onClearSeamTrims;
  final ValueChanged<int> onMergeSeam;
  final bool dragging;

  @override
  Widget build(BuildContext context) {
    if (clips.length < 2) {
      return const SizedBox(height: CutMarker.kHitHeight);
    }
    final editedStarts = <Duration>[];
    var acc = Duration.zero;
    for (final c in clips) {
      editedStarts.add(acc);
      acc += c.editedLength;
    }
    return SizedBox(
      height: CutMarker.kHitHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < clips.length - 1; i++)
            _buildMarker(i, editedStarts),
        ],
      ),
    );
  }

  Widget _buildMarker(int seamIndex, List<Duration> editedStarts) {
    final seamX = editedStarts[seamIndex + 1].inMilliseconds /
        1000.0 *
        pixelsPerSecond;
    final hidden = hiddenSecondsAtSeam(clips, seamIndex);
    return Positioned(
      key: ValueKey('cut-marker-strip-$seamIndex'),
      left: seamX - CutMarker.kHitWidth / 2,
      top: 0,
      width: CutMarker.kHitWidth,
      height: CutMarker.kHitHeight,
      child: CutMarker(
        hiddenSeconds: hidden,
        dragFade: dragging,
        onTap: () {
          if (hidden > Duration.zero) {
            onClearSeamTrims(seamIndex);
          } else {
            onMergeSeam(seamIndex);
          }
        },
      ),
    );
  }
}
