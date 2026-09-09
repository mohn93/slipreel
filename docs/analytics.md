# App analytics (PostHog)

Lightweight, privacy-respecting product analytics for the desktop app. Same
PostHog project as the marketing site (see
[`docs/deploy/posthog-analytics.md`](deploy/posthog-analytics.md)); web vs app is
distinguished by the `source` property, not a separate project.

## How it works

- A thin Dart client (`packages/screen_recorder/lib/analytics/`) POSTs events
  directly to PostHog's US `/batch/` endpoint. No `posthog_flutter` SDK — that
  package targets iOS/Android/web and does not support desktop.
- Events retain their identity at capture time, including in their atomic disk
  queue. Each queue is bounded to 500 events and roughly 1 MiB; events over
  64 KiB are rejected. Oldest events are dropped when limits are reached.
- Delivery uses batches of at most 100 events. Failed attempts back off from
  five seconds to five minutes. Disposal cannot restart the retry timer.
- Anonymous identities are random per launch and after sign-out. Signed-in
  events use the account ID. A shared Mac never joins account A to B through
  a persistent device identity. Queued events are never relabeled at delivery.
- Legacy queue entries without an owner are discarded on migration because
  their original account cannot be established safely. This affects pending
  telemetry/feedback only, not projects, recordings, licenses, or preferences.

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

## Attribution (identify)

The desktop app joins a fresh anonymous session to its first authenticated
account. Later account switches change the identity of future events without
joining two known accounts. Sign-out creates a new anonymous session. Identity
is also retained for queued diagnostics and feedback across restarts.

Website sign-in, pricing, success and account pages do not load analytics;
they do not send checkout email addresses to PostHog. Account IDs are not
anonymous data. Optional in-app feedback reply email is explicitly sent to
PostHog (US), alongside the scrubbed feedback message. Settings, onboarding,
and the public privacy policy disclose this behavior.

Feedback shows “sent” only after HTTP acknowledgement. A successful local
write with failed delivery shows “saved on this Mac”; an unavailable transport
or failed disk/network combination keeps the form open with an email fallback.

## Where events fire

Instrumentation is centralized where practical: `main.dart` watches provider
state via `ref.listenManual` for recording lifecycle, the opt-out toggle, and
entitlement activation. Export / paywall / manual-zoom events fire from
`playback_screen.dart`, where the metadata lives.
