# Error Tracking + In-App Feedback — Design

Date: 2026-09-02
Status: Draft for review
Branch: `feat/error-tracking-feedback`

## 1. Goal

Give the desktop app remote visibility into failures and a way for users to tell
us when something is wrong, so we can find and fix issues we can't reproduce
locally. Two capabilities:

- **Error tracking** — Dart exceptions (uncaught + selected manual captures) and,
  as a fast-follow, native crashes (ffmpeg / whisper / ScreenCaptureKit / helper
  binaries), delivered to PostHog **Error Tracking** as `$exception` events.
- **In-app feedback** — a "Send feedback" form (idea / problem, message, optional
  email, optional attached diagnostics) delivered as a `feedback_submitted` event.

Everything reuses the existing PostHog `/batch/` pipeline. No new analytics vendor,
no `posthog_flutter` SDK, no Firebase/Crashlytics (unsupported on macOS desktop).

### Delivery split

- **v1a** — Dart error tracking + feedback form + the new consent toggle. Rides the
  existing pipeline; low risk. Ship first.
- **v1b** — Native crash post-mortem forwarding (`NativeCrashScanner`). The fiddliest
  part (parsing macOS crash reports); ship as a fast-follow once v1a is proven.

## 2. Non-goals

- No symbolicated native backtraces. Native reports carry binary + offset frames only.
- No in-process native crash handler (that would require a Sentry-class dependency).
- No PostHog Surveys / server-rendered survey definitions (we don't ship the SDK).
- No session replay, no sampling (unnecessary at current scale).
- No change to the existing product-analytics events or funnel behavior.

## 3. Guiding architecture

`AnalyticsService` today fuses two concerns: **transport** (in-memory queue → bounded
on-disk mirror → debounced `/batch/` POST → retry-on-failure) and **policy** (product
events, gated by `shareAnalytics`, plus `identify` and super-properties).

We extract the transport into a reusable, policy-free **`PostHogSink`**, then run three
thin consumers over it — each with its own queue file and its own gate:

| Consumer | Events | Queue file | Gate |
|---|---|---|---|
| `AnalyticsService` (refactored) | product events, `$identify` | `analytics_queue.json` | `shareAnalytics` |
| `DiagnosticsService` (new) | `$exception` (Dart + native) | `diagnostics_queue.json` | `shareDiagnostics` |
| `FeedbackService` (new) | `feedback_submitted` | `feedback_queue.json` | **always on** |

Rationale: the separate diagnostics consent means analytics and diagnostics must be
gated independently, and `setEnabled(false)` clears only its own queue. Feedback is an
explicit user action, so submitting it *is* the consent — it is never gated by a toggle.

`AnalyticsService`'s public API is unchanged; the existing analytics tests keep the
refactor honest.

## 4. Components

### 4.1 `PostHogSink` (new — extracted transport)

Owns queue mechanics only; knows nothing about gating or event semantics.

- Constructor: `{ AnalyticsQueueStore store, String distinctId, String projectKey,
  String host, http.Client client, Duration flushDebounce, DateTime Function() now }`.
- `void enqueue(PostHogEvent event)` — append, mirror to disk, schedule debounced flush.
- `Future<void> flush()` — POST the whole queue to `$host/batch/`; on 2xx remove exactly
  what was sent (events captured during the POST survive); on failure keep the queue and
  reschedule. Same semantics as the current `AnalyticsService.flush`.
- `void setDistinctId(String id)` — update the id used at send time.
- `Future<void> clear()` — drop in-memory + on-disk queue (used on opt-out).
- `Future<void> dispose()` — final flush + close client.
- Gating stays out of the sink. `_configured` (real `phc_` key present) stays a gate so
  unconfigured/dev builds no-op.

`PostHogEvent` is the current `AnalyticsEvent` generalized to any event name +
properties (it already is name + timestamp + properties). Reused by all three consumers.

### 4.2 `AnalyticsService` (refactored over the sink)

Same external API (`capture`, `identify`, `setEnabled`, `load`, `flush`, `dispose`,
`enabled`, the `analyticsServiceProvider`, and the `captureAnalytics` WidgetRef
extension). Internally delegates transport to a `PostHogSink`; keeps `_enabled`
(`shareAnalytics`), super-properties, and `identify`. Opt-out still discards the buffer.

### 4.3 `DiagnosticsService` (new)

- Gated by `shareDiagnostics`; owns its own `PostHogSink` (queue `diagnostics_queue.json`).
- `void captureException(Object error, StackTrace? stack, { bool handled = true,
  Map<String,Object?>? context })` — builds a scrubbed `$exception` event (see §5),
  attaches a breadcrumb snapshot, enqueues if enabled.
- `void captureNativeCrash(NativeCrashReport report)` — (v1b) builds a native
  `$exception` event (`mechanism.type: 'native'`, `handled: false`).
- `void setDistinctId(String id)` — kept in sync with analytics `identify` (§8).
- `setEnabled(bool)` — on `false`, clear the diagnostics queue; on `true`, resume.
- Flood control: cap `$exception` events per app session (default 50) and collapse
  repeats of the same fingerprint within a short window (default 30 s).

### 4.4 `ExceptionEventBuilder` + `PiiScrubber` (new — pure)

Pure functions, the correctness core, unit-tested in isolation.

- `PiiScrubber`: replace the user's home dir prefix with `~` in any string; cap message
  and each breadcrumb to a max length; cap list sizes. Applied to messages, every stack
  frame `filename`, and breadcrumbs.
- `ExceptionEventBuilder.fromDart(error, stack, breadcrumbs, meta, handled)` and
  `.fromNative(report, breadcrumbs, meta)` → a `PostHogEvent` named `$exception` with the
  §5 shape, already scrubbed, with a stable `$exception_fingerprint`.

### 4.5 `Breadcrumbs` ring buffer + `BreadcrumbLogOutput` (new)

- A bounded ring buffer (default 40 entries) of recent `AppLogger` lines
  (`{ ts, zone, level, message }`, message length-capped at insert).
- Fed by a new `LogOutput` added alongside the existing `ZoneLogOutput` in
  `AppLogger.initialize` (multi-output), so instrumentation is centralized and the app's
  console logging is unchanged.
- `DiagnosticsService` / `FeedbackService` read a scrubbed snapshot at capture time.

### 4.6 `NativeCrashScanner` (v1b, new)

- Runs once at launch (after app-support dir is known, before/around analytics init).
- Scans `~/Library/Logs/DiagnosticReports/*.ips` (and legacy `*.crash`), keeping only
  reports whose process/binary matches Slipreel or a bundled helper (allowlist:
  the app binary, `ffmpeg`, `ffprobe`, `whisper-cli`, and the ScreenCaptureKit host).
- Skips anything older than a persisted watermark (`native_crash_watermark.json`:
  last-scanned timestamp + set of seen report ids). Dedupes by report filename/hash.
  Caps the number forwarded per launch (default 10, newest first).
- Parses minimal fields from the `.ips` JSON: exception/signal type, faulting binary,
  crashed thread's top N frames (binary + offset — unsymbolicated), OS version.
- Emits scrubbed native `$exception` events via `DiagnosticsService.captureNativeCrash`,
  then advances the watermark. Entirely best-effort: any parse failure is logged and
  skipped, never thrown.

### 4.7 `FeedbackService` (new)

- `Future<void> submit(FeedbackReport report)` → builds a `feedback_submitted` event and
  enqueues into an **always-on** `PostHogSink` (queue `feedback_queue.json`), so it is
  offline-tolerant and independent of both toggles.
- `FeedbackReport = { FeedbackType type (idea|problem), String message, String? email,
  bool attachDiagnostics }`. When `attachDiagnostics` is true, the event carries
  `{ app_version, os, breadcrumbs (scrubbed), last_exception_fingerprint? }`; otherwise
  only `{ type, message, email? }` plus the standard `source`/`platform`.

### 4.8 Global error handlers (`main.dart`)

- Wrap `runApp` in `runZonedGuarded(..., (e, st) => diagnostics.captureException(e, st,
  handled: false))`.
- `FlutterError.onError` → keep the current behavior (dump in debug) **and** forward to
  `diagnostics.captureException(details.exception, details.stack, handled: false)`.
- `PlatformDispatcher.instance.onError` → forward and return `true`.
- Manual captures (v1a): add `diagnostics.captureException(e, st)` at the existing
  swallow-and-log sites where a failure is meaningful — analytics flush already logs and
  swallows; export/recording pipeline failures; native plugin boundaries. Handled = true.

### 4.9 Consent state + Settings UI

- `GlobalPreferences.shareDiagnostics` — `bool`, default **true**, absent→true (existing
  users keep the default), mirroring `shareAnalytics` in the model, `copyWith`, `toJson`,
  `fromJson`, and the store.
- `GlobalPreferencesController.setShareDiagnostics(bool)`.
- Settings → Privacy: a second `SwitchListTile` — *"Send crash & error reports"* — with a
  subtitle in the same careful tone as the analytics toggle (states that reports are
  scrubbed of file paths and never include recordings).
- `_wireAnalyticsObservers` gains a `ref.listen` on `shareDiagnostics` →
  `diagnostics.setEnabled(next)`.

### 4.10 Feedback UI

- A `FeedbackSheet` (or screen) with: segmented **Idea / Problem**, a multiline message
  field (required), an optional email field, and an **"Attach diagnostics"** checkbox with
  a one-line note of exactly what is attached. Submit → `FeedbackService.submit`, then an
  `AppAlerts.success` confirmation.
- Entry points: a "Send feedback" row in Settings, and a Help-menu item.

## 5. The `$exception` event shape

PostHog Error Tracking is built on the `$exception` event. Each capture is:

```jsonc
{
  "event": "$exception",
  "distinct_id": "<same id as analytics>",
  "properties": {
    "$exception_list": [{
      "type": "RangeError",                  // Dart class, or native signal (e.g. SIGSEGV)
      "value": "<scrubbed message>",
      "mechanism": { "handled": false, "type": "flutter" },  // or "native"
      "stacktrace": {
        "type": "raw",
        "frames": [
          { "filename": "~/…/foo.dart", "function": "Foo.bar", "lineno": 42, "in_app": true }
        ]
      }
    }],
    "$exception_fingerprint": "<stable grouping key>",
    "source": "app",
    "platform": "macos",
    "app_version": "1.0.0+1",
    "breadcrumbs": ["<scrubbed recent log lines>"]
  }
}
```

- `handled`: `false` for uncaught + native crashes, `true` for manual captures.
- Fingerprint: for Dart, `type` + top in-app frame (function+file); for native, signal +
  faulting binary + top frame. Deterministic so PostHog groups issues cleanly.
- Frames scrubbed (`filename` → `~`), message length-capped, list sizes capped.

**Verification requirement:** the exact `$exception_list` shape must be validated against
a live dev PostHog project during implementation. A slightly malformed event still
ingests but won't group into an issue, so a unit test alone is insufficient — a real
end-to-end check that an issue appears under Error Tracking is part of "done".

## 6. Data flow

1. **Dart exception** → global handler or manual call → `ExceptionEventBuilder` (scrub +
   breadcrumbs + fingerprint) → `DiagnosticsService` (if `shareDiagnostics`) → sink →
   `/batch/`.
2. **Native crash** (v1b) → *next launch* → `NativeCrashScanner` reads new matching
   reports past the watermark → parse → `captureNativeCrash` → sink → advance watermark.
3. **Feedback** → `FeedbackSheet` → `FeedbackService.submit` → always-on sink → `/batch/`.

## 7. Privacy / scrubbing (baked in)

- Home dir → `~` in all strings (paths in stacks, messages, native reports contain
  `/Users/<realname>/`).
- Message + each breadcrumb length-capped; `$exception_list` and breadcrumb counts capped.
- Only an allowlist of meta properties is ever attached — no arbitrary payloads.
- `distinct_id` reuses the analytics device fingerprint / identified user id (one-way
  hash; no new identifier introduced).
- Diagnostics gated by `shareDiagnostics`; feedback gated by the act of submitting.
- Breadcrumbs (log lines) are the main added PII surface — mitigated by scrub-at-attach,
  a small buffer, and only being sent attached to a report the user's toggle/action allows.

## 8. distinct_id synchronization

`AnalyticsService.identify(userId)` currently switches the analytics id to the
entitlement `sub`. The observer that calls `identify` will also call
`diagnostics.setDistinctId(userId)` (and the feedback sink's `setDistinctId`) so
exceptions and feedback tie to the same PostHog person as product events. Before
identify, all three use the same device fingerprint resolved in `_resolveAnalyticsDistinctId`.

## 9. Wiring in `main()`

Order (extending the existing sequence around line 230):

1. Resolve `distinctId`, app-support path, and app version (`package_info_plus`).
2. Build `AnalyticsService` (unchanged behavior).
3. Build `DiagnosticsService` with `enabled: initialGlobalPreferences.shareDiagnostics`,
   shared `distinctId`, super-meta (`source`, `platform`, `app_version`), breadcrumb buffer.
4. Build `FeedbackService` (always-on sink).
5. Install the breadcrumb `LogOutput` in `AppLogger.initialize`.
6. Install global handlers (`FlutterError.onError`, `PlatformDispatcher.onError`), and
   wrap `runApp` in `runZonedGuarded`.
7. (v1b) Run `NativeCrashScanner` best-effort and forward any new reports.
8. Add provider overrides: `diagnosticsServiceProvider`, `feedbackServiceProvider`,
   `globalPreferencesController` already exists (extended with `shareDiagnostics`).
9. On app close, `diagnostics.dispose()` / `feedback.dispose()` flush alongside analytics.

## 10. Testing

- `PiiScrubber` + `ExceptionEventBuilder`: table tests — home paths gone, caps enforced,
  fingerprint stable across identical errors and distinct across different ones.
- `PostHogSink`: extend the existing analytics transport tests (offline retry, 2xx
  removes exactly what was sent, `clear` empties disk + memory).
- `AnalyticsService`: existing tests must still pass unchanged (refactor guard).
- `DiagnosticsService`: disabled → no enqueue and queue cleared; enabled → enqueues;
  flood cap + fingerprint collapse honored.
- `FeedbackService`: builds expected event; sends regardless of `shareDiagnostics`;
  `attachDiagnostics` toggles the diagnostics block.
- `NativeCrashScanner` (v1b): fixture `.ips` files → expected events; watermark advance;
  dedupe; non-matching processes ignored; malformed report skipped, not thrown.
- Live verification (part of "done"): dev PostHog key via `--dart-define`; confirm a
  forced `$exception` appears under Error Tracking as a grouped issue and a
  `feedback_submitted` event appears.

## 11. Risks / tradeoffs

- **Transport extraction touches shipped analytics code.** Low risk (API unchanged, tests
  cover it); chosen over duplicating the transport across three queues.
- **Native frames are unsymbolicated.** PostHog issues show binary + offset, not function
  names. Enough to see *that* and *how often* a helper crashes; matches the "track issues"
  goal. Full symbolication is out of scope for v1.
- **Breadcrumbs add mild PII surface** — mitigated as in §7.
- **`.ips` format drift** across macOS versions — parser is defensive and best-effort;
  failure to parse a report is logged and skipped.

## 12. File-level change map (indicative)

v1a:
- `lib/analytics/posthog_sink.dart` (new — extracted transport)
- `lib/analytics/analytics_service.dart` (refactor over sink; API unchanged)
- `lib/analytics/analytics_event.dart` (generalize to `PostHogEvent` or alias)
- `lib/diagnostics/diagnostics_service.dart` (new)
- `lib/diagnostics/exception_event_builder.dart` (new, pure)
- `lib/diagnostics/pii_scrubber.dart` (new, pure)
- `lib/diagnostics/breadcrumbs.dart` (new)
- `lib/feedback/feedback_service.dart` (new)
- `lib/ui/…/feedback_sheet.dart` (new)
- `lib/ui/screens/settings_screen.dart` (second privacy toggle + feedback entry)
- `lib/state/global_preferences_store.dart` + `_controller.dart` (add `shareDiagnostics`)
- `packages/slipreel_engine/lib/utils/app_logger.dart` (breadcrumb `LogOutput`)
- `lib/main.dart` (build/wire services, global handlers, `runZonedGuarded`)
- tests under `test/analytics`, `test/diagnostics`, `test/feedback`

v1b:
- `lib/diagnostics/native_crash_scanner.dart` (new) + watermark store
- `lib/diagnostics/native_crash_report.dart` (parsed model)
- `main.dart` scanner wiring
- `test/diagnostics/native_crash_scanner_test.dart` + `.ips` fixtures
