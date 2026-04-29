/// A user-drawn region of a specific display, in display-pixel coordinates.
class RegionSelection {
  final String displayId;
  final int x;
  final int y;
  final int widthPx;
  final int heightPx;

  const RegionSelection({
    required this.displayId,
    required this.x,
    required this.y,
    required this.widthPx,
    required this.heightPx,
  });

  Map<String, dynamic> toMap() => {
        'displayId': displayId,
        'x': x,
        'y': y,
        'width': widthPx,
        'height': heightPx,
      };

  factory RegionSelection.fromMap(Map<String, dynamic> map) {
    return RegionSelection(
      displayId: map['displayId'] as String? ?? '',
      x: (map['x'] as num?)?.toInt() ?? 0,
      y: (map['y'] as num?)?.toInt() ?? 0,
      widthPx: (map['width'] as num?)?.toInt() ?? 0,
      heightPx: (map['height'] as num?)?.toInt() ?? 0,
    );
  }
}
