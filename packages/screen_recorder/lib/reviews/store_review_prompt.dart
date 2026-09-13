import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../distribution/distribution_channel.dart';

final storeReviewPromptProvider = Provider<StoreReviewPrompt>((ref) {
  const key = 'store_review_requested_after_export_v1';
  return StoreReviewPrompt(
    isStore: DistributionChannel.isAppStore,
    wasRequested: () async =>
        (await SharedPreferences.getInstance()).getBool(key) ?? false,
    rememberRequest: () async {
      await (await SharedPreferences.getInstance()).setBool(key, true);
    },
    requestNative: () async =>
        await const MethodChannel(
          'slipreel/store',
        ).invokeMethod<bool>('requestReview') ??
        false,
  );
});

/// One request per installation, only after real value has been delivered.
/// Apple decides whether to show its UI; a request is not proof of a rating.
class StoreReviewPrompt {
  StoreReviewPrompt({
    required this.isStore,
    required this.wasRequested,
    required this.rememberRequest,
    required this.requestNative,
    Future<void> Function()? wait,
  }) : wait = wait ?? (() => Future<void>.delayed(const Duration(seconds: 3)));
  final bool isStore;
  final Future<bool> Function() wasRequested;
  final Future<void> Function() rememberRequest;
  final Future<bool> Function() requestNative;
  final Future<void> Function() wait;
  bool _busy = false;
  bool _requested = false;

  Future<void> afterSuccessfulExport({required bool Function() isIdle}) async {
    if (!isStore || _busy || _requested) return;
    _busy = true;
    try {
      if (await wasRequested()) {
        _requested = true;
        return;
      }
      await wait();
      if (!isIdle()) return;
      if (await requestNative()) {
        _requested = true;
        await rememberRequest();
      }
    } catch (_) {
      // Review requests must never change the successful export outcome.
    } finally {
      _busy = false;
    }
  }
}
