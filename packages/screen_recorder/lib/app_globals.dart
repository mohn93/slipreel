import 'package:flutter/widgets.dart';

/// Navigator key for the root [MaterialApp]. Surfaces outside the normal widget
/// tree (recording toasts, wake modals, the macOS app-menu handler) use it to
/// reach a valid [BuildContext]/[NavigatorState]. Lives in its own file so
/// non-`main.dart` libraries (e.g. app-menu actions) can import it without a
/// circular dependency on `main.dart`.
final rootNavigatorKey = GlobalKey<NavigatorState>();
