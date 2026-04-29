import 'screen_info.dart';
import 'window_info.dart';

/// Combined window + screen list returned by `listSources`.
class SourceList {
  final List<WindowInfo> windows;
  final List<ScreenInfo> screens;

  const SourceList({
    this.windows = const [],
    this.screens = const [],
  });

  Map<String, dynamic> toMap() => {
        'windows': windows.map((w) => w.toJson()).toList(),
        'screens': screens.map((s) => s.toJson()).toList(),
      };

  factory SourceList.fromMap(Map<String, dynamic> map) {
    final rawWindows = (map['windows'] as List?) ?? const [];
    final rawScreens = (map['screens'] as List?) ?? const [];
    return SourceList(
      windows: rawWindows
          .map((e) => WindowInfo.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      screens: rawScreens
          .map((e) => ScreenInfo.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}
