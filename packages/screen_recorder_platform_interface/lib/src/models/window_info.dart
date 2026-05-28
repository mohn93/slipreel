/// Information about an available window.
///
/// IMPORTANT: [x], [y], [width], and [height] are in DISPLAY POINTS, not
/// pixels. On Retina displays (`backingScaleFactor` > 1) the actual
/// captured video dimensions are `points × backingScaleFactor` pixels —
/// e.g. a 1280×720-point window typically records as 2560×1440 px on a
/// 2× display. Don't use these bounds as encoder dimensions; resolve
/// pixel dimensions from the capture pipeline (see e.g. macOS
/// `captureDimensions`).
class WindowInfo {
  final String id;
  final String title;
  final String ownerName;
  final int x;
  final int y;
  final int width;
  final int height;
  final bool isOnScreen;

  const WindowInfo({
    required this.id,
    required this.title,
    required this.ownerName,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.isOnScreen = true,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'ownerName': ownerName,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'isOnScreen': isOnScreen,
    };
  }

  factory WindowInfo.fromJson(Map<String, dynamic> json) {
    return WindowInfo(
      id: json['id'] as String,
      title: json['title'] as String,
      ownerName: json['ownerName'] as String,
      x: json['x'] as int,
      y: json['y'] as int,
      width: json['width'] as int,
      height: json['height'] as int,
      isOnScreen: json['isOnScreen'] as bool? ?? true,
    );
  }

  @override
  String toString() {
    return 'WindowInfo(id: $id, title: $title, app: $ownerName, pos: ($x, $y), size: ${width}x$height)';
  }
}
