/// Identifies what (if anything) is currently selected in the editor
/// timeline. Drives the inspector panel: when non-null the rail's
/// "format" tabs are replaced by a context-specific properties view
/// for the selected element.
sealed class TimelineSelection {
  const TimelineSelection();
}

/// The user clicked the main video clip bar.
class ClipSelected extends TimelineSelection {
  const ClipSelected();
}

/// The user clicked a zoom pill. [index] points into the playback
/// screen's zoom-regions list (so callbacks can mutate the right one).
class ZoomSelected extends TimelineSelection {
  const ZoomSelected(this.index);
  final int index;
}
