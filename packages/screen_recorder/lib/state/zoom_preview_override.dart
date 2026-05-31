import 'package:flutter/foundation.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

/// Live placement-picker override. While the user is dragging the
/// focal handle in the zoom inspector, this holds the in-flight
/// [ZoomRegion] that should replace the normal
/// `ZoomRegion.activeAt(playhead, regions)` result. Cleared on drag
/// release and on any change to the selected zoom index.
class ZoomPreviewOverride extends ValueNotifier<ZoomRegion?> {
  ZoomPreviewOverride() : super(null);
}
