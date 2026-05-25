# Compact Recording Bar — Deferred Follow-ups

These were intentionally deferred from the initial implementation (2026-05-25)
and are flagged here so they aren't silently dropped.

1. **"Show all windows" strict-filter setting.** The spec moved this toggle to
   Settings. Deferred: `FrameSettingsProvider` is a transient `ChangeNotifier`
   with no persistence home, so a new persisted setting + threading `strictFilter`
   through `pickSource`/native is needed. The picker currently uses the sensible
   default (`SourceCatalog.applyStrictFilter`, dropping tiny/system windows).

2. **Screen-recording permission CTA.** The spec wanted a denied-permission path
   that shows `PermissionCta` in a panel. Deferred (the plan downgraded this to a
   flagged follow-up). Today: Window mode shows the empty-overlay hint ("No windows
   to record"); Display mode can fail into `RecordingStatus.error`. Add a
   `checkPermissions()` gate before `pickSource`/`selectRegion` and surface denial
   by morphing to a panel with guidance.

3. **User-facing recording-error feedback.** `RecordingStatus.error` currently
   returns silently to the bar (a SnackBar is useless in the 64px bar window).
   Surface errors by briefly morphing to a panel with the message.

4. **App-icon matching.** `SourcePickerOverlay.appIcon(ownerName:)` matches by
   `NSRunningApplication.localizedName`; prefer matching the window's
   `bundleIdentifier` (available on the `RawWindow`) for robustness.
