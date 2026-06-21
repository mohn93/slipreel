import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/models/device_frame.dart';

/// Async-loaded device-frame catalog (bundled manifest). Inspector
/// widgets watch this; it resolves once and stays cached for the session.
final deviceFrameCatalogProvider = FutureProvider<DeviceFrameCatalog>(
  (ref) => loadDeviceFrameCatalog(),
);
