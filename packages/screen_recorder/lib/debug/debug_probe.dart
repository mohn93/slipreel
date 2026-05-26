import 'package:flutter/widgets.dart';

/// Seam for optional, debug-only runtime instrumentation.
///
/// Production code talks only to this interface, so the app compiles and
/// runs with no external probe package present. To wire the real
/// agent-wires probe locally, see `lib/debug/README.md`.
abstract class DebugProbe {
  /// Installs runtime introspection hooks (VM-service extensions, etc.).
  void install();

  /// Optional navigator observer for route tracking. Null when disabled.
  NavigatorObserver? navigatorObserver();
}

/// Default no-op probe used in all committed builds.
class NoopDebugProbe implements DebugProbe {
  const NoopDebugProbe();

  @override
  void install() {}

  @override
  NavigatorObserver? navigatorObserver() => null;
}

/// Mutable global the app reads. Override before `main()` runs (e.g. from a
/// local `main_dev.dart`) to install a real probe.
DebugProbe debugProbe = const NoopDebugProbe();
