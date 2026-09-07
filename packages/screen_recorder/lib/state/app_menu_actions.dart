import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_globals.dart';
import '../licensing/licensing_controller.dart';
import '../ui/screens/settings_screen.dart';
import 'window_mode.dart';
import 'window_mode_controller.dart';

/// App-wide entry points for the "Settings" and "Manage account" commands, so
/// the macOS app menu and the editor top bar route through one place instead
/// of each re-implementing panel navigation.
class AppMenuActions {
  AppMenuActions(this._ref);
  final Ref _ref;

  bool _openingSettings = false;

  /// Open the Settings panel. From the bar we switch the window to panel mode
  /// and restore the bar when it closes; from a panel that's already open (the
  /// editor) we just push Settings on top and return to it on close. Guarded so
  /// a repeated trigger (e.g. holding Cmd+,) can't stack duplicate screens.
  Future<void> openSettings() async {
    if (_openingSettings) return;
    _openingSettings = true;
    try {
      final nav = rootNavigatorKey.currentState;
      if (nav == null) return;
      final wasBar = _ref.read(windowModeControllerProvider) == WindowMode.bar;
      final mode = _ref.read(windowModeControllerProvider.notifier);
      if (wasBar) await mode.showPanel();
      await nav.push(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      );
      if (wasBar) await mode.showBar();
    } finally {
      _openingSettings = false;
    }
  }

  /// Open the web account page (billing portal, devices, sign-in/out).
  Future<void> manageAccount() =>
      _ref.read(licensingControllerProvider.notifier).openAccount();
}

final appMenuActionsProvider =
    Provider<AppMenuActions>((ref) => AppMenuActions(ref));
