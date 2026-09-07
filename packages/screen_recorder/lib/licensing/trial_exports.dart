import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'license_store.dart';

/// Local, account-free evaluation allowance. This is not an anti-piracy system.
/// A single app-wide instance prevents two windows spending the final slot.
final trialExportsProvider = ChangeNotifierProvider<TrialExports>((ref) =>
    throw StateError('TrialExports must be initialized at startup'));

/// Refreshes all open editors after a successful trial export.
final trialExportsRemainingProvider = FutureProvider<int>(
  (ref) => ref.watch(trialExportsProvider).remaining,
);

class TrialExports extends ChangeNotifier {
  TrialExports(this.store);
  final SecureKV store;
  static const limit = 3;
  static const storageKey = 'trial_exports_completed_v1';
  bool _busy = false;

  void _quotaChanged() => notifyListeners();

  Future<int> get remaining async {
    final raw = await store.read(storageKey);
    final used = raw == null ? 0 : int.tryParse(raw);
    if (used == null || used < 0) return 0;
    return (limit - used).clamp(0, limit);
  }

  /// Reserve before starting a pipeline; commit only after successful delivery.
  /// Failure, cancellation, or a process crash leaves the allowance intact.
  Future<TrialExportLease?> reserve() async {
    if (_busy) return null;
    _busy = true;
    try {
      final left = await remaining;
      if (left == 0) {
        _busy = false;
        return null;
      }
      return TrialExportLease._(this, limit - left);
    } catch (_) {
      _busy = false;
      rethrow;
    }
  }
}

class TrialExportLease {
  TrialExportLease._(this.owner, this.used);
  final TrialExports owner;
  final int used;
  bool _closed = false;
  Future<void> complete({required bool successful}) async {
    if (_closed) return;
    _closed = true;
    try {
      if (successful) {
        await owner.store.write(TrialExports.storageKey, '${used + 1}');
        owner._quotaChanged();
      }
    } finally {
      owner._busy = false;
    }
  }
}
