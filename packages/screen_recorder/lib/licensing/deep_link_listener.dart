import 'dart:async';

import 'package:app_links/app_links.dart';

import 'licensing_controller.dart';

/// Bridges app_links to the LicensingController. Forwards the cold-start link
/// (if the app was launched by a slipreel:// URL) and every subsequent link.
class DeepLinkListener {
  DeepLinkListener(this._controller, {AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  final LicensingController _controller;
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _sub;

  Future<void> start() async {
    final initial = await _appLinks.getInitialLink();
    if (initial != null) {
      await _controller.handleDeepLink(initial);
    }
    _sub = _appLinks.uriLinkStream.listen((uri) {
      _controller.handleDeepLink(uri);
    });
  }

  Future<void> dispose() async {
    await _sub?.cancel();
  }
}
