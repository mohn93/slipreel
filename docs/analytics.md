# App analytics (PostHog)

Lightweight, privacy-respecting product analytics for the desktop app. Same
PostHog project as the marketing site (see
[`docs/deploy/posthog-analytics.md`](deploy/posthog-analytics.md)); web vs app is
distinguished by the `source` property, not a separate project.

## How it works

- A thin Dart client (`packages/screen_recorder/lib/analytics/`) POSTs events
  directly to PostHog's US `/batch/` endpoint. No `posthog_flutter` SDK — that
  package targets iOS/Android/web and does not support desktop.
- Events are buffered in memory and mirrored to a bounded on-disk queue
  (`<appSupport>/analytics_queue.json`), so nothing is lost offline; delivery is
  best-effort and never blocks or crashes the app.
- `distinct_id` is the device fingerprint (`DeviceFingerprint.compute()`) — a
  sha256 of the hardware id that already backs licensing. The raw id never
  leaves the machine. If the platform can't supply one, a random per-install id
  is persisted instead.

## Privacy

- **Opt-out, on by default.** Toggle in Settings → Privacy
  (`GlobalPreferences.shareAnalytics`); disclosed on the final onboarding page.
  Turning it off discards any buffered events, not just future ones.
- **Content-free.** Events record only that an action happened plus cheap,
  non-identifying metadata (durations, formats, counts). Never file paths,
  window titles, captured pixels, or recording contents — this is a screen
  recorder. Export failures capture the error *type*, never the message (which
  can contain paths).

## Configuring the key

The public (write-only) project key is baked in at build time, so it is not in
source. Debug/dev builds with no key defined no-op entirely.

```bash
flutter build macos --dart-define=SLIPREEL_POSTHOG_KEY=phc_your_project_key
# optional, to point at a local/dev PostHog:
#   --dart-define=SLIPREEL_POSTHOG_HOST=http://localhost:8000
```

Release builds must pass `--dart-define=SLIPREEL_POSTHOG_KEY=...` (add it to the
`flutter build macos` invocation in `scripts/release-macos.sh` or the CI release
workflow) for analytics to be active in shipped copies.

## Event taxonomy

Kept small and meaningful — the funnel that matters is
open → record → export → purchase. Names are in
`lib/analytics/analytics_events.dart`.

| Event | Properties |
|-------|-----------|
| `app_opened` | (super props only) |
| `screen_viewed` | `screen` = onboarding / editor / settings |
| `recording_started` | — |
| `recording_completed` | `duration_s` |
| `zoom_added` | `mode` = manual *(auto-placement not yet instrumented)* |
| `export_opened` | — (funnel entry: user initiated an export) |
| `paywall_shown` | `reason` (needsPurchase / subscriptionLapsed / updateCeiling) |
| `export_started` | `format`, `resolution`, `fps`, `compression`, `destination` |
| `export_completed` | `format`, `resolution`, `fps`, `realtime_multiple` |
| `export_failed` | `format` + `error_type`, or `reason: not_entitled` |
| `entitlement_activated` | — |

Every event also carries super properties: `source: 'app'` and
`platform` (`macos` / `windows`).

## Where events fire

Instrumentation is centralized where practical: `main.dart` watches provider
state via `ref.listenManual` for recording lifecycle, the opt-out toggle, and
entitlement activation. Export / paywall / manual-zoom events fire from
`playback_screen.dart`, where the metadata lives.
