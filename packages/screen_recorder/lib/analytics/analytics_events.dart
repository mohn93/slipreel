/// Canonical event names, so call sites can't drift on spelling. Keep this
/// list small and meaningful — the funnel that matters is
/// open -> record -> export -> purchase.
abstract class AnalyticsEvents {
  static const appOpened = 'app_opened';
  static const recordingStarted = 'recording_started';
  static const recordingCompleted = 'recording_completed';
  static const zoomAdded = 'zoom_added';
  static const exportStarted = 'export_started';
  static const exportCompleted = 'export_completed';
  static const exportFailed = 'export_failed';
  static const paywallShown = 'paywall_shown';
  static const entitlementActivated = 'entitlement_activated';
}
