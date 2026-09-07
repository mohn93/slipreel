import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../licensing/license_store.dart';

/// Records whether Screen Recording has ever been *requested* — the moment
/// macOS shows its one-time system prompt. The permission UI reads this to
/// avoid stacking our own guide sheet on top of that OS prompt on the very
/// first ask, while still offering the guide to a returning user macOS no
/// longer prompts (`CGRequestScreenCaptureAccess` is a no-op once a decision
/// exists). Persisted so "first ask" is judged across launches, not per session.
class PermissionPromptLog {
  PermissionPromptLog(this._kv);
  final SecureKV _kv;
  static const _screenRecKey = 'screen_recording_requested_v1';

  Future<bool> screenRecordingRequested() async {
    try {
      return (await _kv.read(_screenRecKey)) != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> markScreenRecordingRequested() async {
    try {
      await _kv.write(_screenRecKey, '1');
    } catch (_) {/* best-effort; worst case the guide sheet is delayed a click */}
  }
}

/// Session-only by default; `main()` overrides it with a file-backed store so
/// the "already asked" flag survives relaunches.
final permissionPromptLogProvider = Provider<PermissionPromptLog>(
  (ref) => PermissionPromptLog(InMemorySecureKV()),
);
