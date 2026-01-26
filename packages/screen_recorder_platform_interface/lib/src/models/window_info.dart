/// Information about an available window
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
