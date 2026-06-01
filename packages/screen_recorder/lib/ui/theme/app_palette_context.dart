import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/theme/app_palette.dart';

extension AppPaletteContext on BuildContext {
  /// The active palette installed on the nearest `ThemeData.extensions`.
  /// Throws if no `AppPalette` is registered — the app installs one at
  /// the root via `main.dart`, so missing it is always a bug.
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;
}
