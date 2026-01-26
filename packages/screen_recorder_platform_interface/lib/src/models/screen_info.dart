/// Information about an available screen/display
class ScreenInfo {
  final String id;
  final String name;
  final int width;
  final int height;
  final bool isPrimary;

  const ScreenInfo({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    this.isPrimary = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'width': width,
      'height': height,
      'isPrimary': isPrimary,
    };
  }

  factory ScreenInfo.fromJson(Map<String, dynamic> json) {
    return ScreenInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      width: json['width'] as int,
      height: json['height'] as int,
      isPrimary: json['isPrimary'] as bool? ?? false,
    );
  }

  @override
  String toString() {
    return 'ScreenInfo(id: $id, name: $name, size: ${width}x$height, isPrimary: $isPrimary)';
  }
}
