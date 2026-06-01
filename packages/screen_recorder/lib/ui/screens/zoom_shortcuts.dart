import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Intent fired by `Cmd =`. Steps timeline scale UP by *1.25.
class ZoomTimelineInIntent extends Intent {
  const ZoomTimelineInIntent();
}

/// Intent fired by `Cmd -`. Steps timeline scale DOWN by /1.25.
class ZoomTimelineOutIntent extends Intent {
  const ZoomTimelineOutIntent();
}

/// Activator map. Lives in its own module so it's reachable from
/// tests without spinning up the whole playback screen.
Map<ShortcutActivator, Intent> buildZoomShortcuts() => const {
      SingleActivator(LogicalKeyboardKey.equal, meta: true):
          ZoomTimelineInIntent(),
      // US keyboards: `Cmd + +` is physically `Cmd + Shift + =` (the
      // `+` glyph is shift+= on the same key). SingleActivator defaults
      // `shift: false`, so without this entry pressing `Cmd++` would
      // silently no-op. Match Chrome/Xcode "zoom in" behavior.
      SingleActivator(LogicalKeyboardKey.equal, meta: true, shift: true):
          ZoomTimelineInIntent(),
      SingleActivator(LogicalKeyboardKey.minus, meta: true):
          ZoomTimelineOutIntent(),
    };

/// Action map. Caller injects the read/write closures so the action
/// doesn't depend on a provider directly — testable.
Map<Type, Action<Intent>> buildZoomActions({
  required double Function() getScale,
  required void Function(double next) setScale,
}) =>
    <Type, Action<Intent>>{
      ZoomTimelineInIntent: CallbackAction<ZoomTimelineInIntent>(
        onInvoke: (_) {
          setScale(getScale() * 1.25);
          return null;
        },
      ),
      ZoomTimelineOutIntent: CallbackAction<ZoomTimelineOutIntent>(
        onInvoke: (_) {
          setScale(getScale() / 1.25);
          return null;
        },
      ),
    };
