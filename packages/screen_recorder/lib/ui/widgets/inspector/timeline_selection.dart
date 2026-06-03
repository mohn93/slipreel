/// Identifies what (if anything) is currently selected in the editor
/// timeline. Drives the inspector panel: when non-null the rail's
/// "format" tabs are replaced by a context-specific properties view
/// for the selected element.
sealed class TimelineSelection {
  const TimelineSelection();
}

/// The user clicked a clip slice. [index] points into
/// `state.timeline.clips` so the inspector can edit the right slice.
class SliceSelected extends TimelineSelection {
  const SliceSelected(this.index);
  final int index;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SliceSelected && other.index == index;

  @override
  int get hashCode => index.hashCode;
}

/// The user clicked a zoom pill. [index] points into the playback
/// screen's zoom-regions list (so callbacks can mutate the right one).
class ZoomSelected extends TimelineSelection {
  const ZoomSelected(this.index);
  final int index;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomSelected && other.index == index;

  @override
  int get hashCode => index.hashCode;
}
