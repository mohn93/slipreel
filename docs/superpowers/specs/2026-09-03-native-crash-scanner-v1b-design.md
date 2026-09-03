# Native Crash Scanner (v1b) — Design

Date: 2026-09-03
Status: Draft for review
Branch: `feat/native-crash-scanner`
Follows: `2026-09-02-error-tracking-feedback-design.md` (v1a, shipped — PRs #84/#85 merged to main)

## 1. Goal

Give us remote visibility into **native** crashes — the ones v1a can't see because
they happen outside the Dart VM: the bundled helper binaries (`ffmpeg`, `ffprobe`,
`whisper-cli`) dying mid-job, and in-process native code (ScreenCaptureKit, the
Flutter engine) taking the whole app down.

The driving requirement is **correlation, not symbolication**: for each native crash
we want to know *what the user was doing* — tie it back to the same breadcrumb trail
and activity context a live Dart error would carry in v1a, and to the handled Dart
failure v1a already reports for the same incident. Knowing *that* a helper crashes and
*how often* falls out for free; deep per-frame debugging does not, and is explicitly
not the goal.

Native crashes are delivered to the **same** PostHog Error Tracking pipeline as v1a —
as `$exception` events over the existing `/batch/` transport — so they group and sit
alongside Dart errors and feedback in one place. To make same-session correlation
work (§5), v1b adds a lightweight per-launch `session_id` to diagnostics events; v1a
today emits only a per-install `distinct_id`, which can't distinguish sessions.

## 2. Non-goals

- **No symbolicated native backtraces.** Reports carry binary + offset frames only.
  Enough to see which binary crashed and group recurrences; not function names.
- **No reuse of `mechanism.type` for nativeness.** v1a deliberately dropped that field
  (PostHog's `mechanism` is `{handled, synthetic}` only). Native events are marked by
  per-frame `lang: 'native'` plus a top-level `exception_platform: 'native'` property.
- **No in-process native crash handler.** That needs a Sentry-class dependency with
  its own signal handlers and a separate ingestion silo that cannot see v1a's
  breadcrumbs, meta, or feedback. Rejected — it defeats the correlation goal.
- **No new analytics vendor / SDK.** Reuses `PostHogSink` + `DiagnosticsService` +
  `ExceptionEventBuilder` + `PiiScrubber` from v1a unchanged in shape.
- **No forwarding of non-Slipreel crashes.** We only forward reports whose responsible
  process is our app or a bundled helper.
- **No uploading of raw `.ips` files.** We extract a minimal, scrubbed set of fields.
- **No live symbolication, no dSYM upload, no crash-time UI.** Post-mortem only.

## 3. Why post-mortem next-launch scanning

macOS already writes a full crash report (`.ips`) to
`~/Library/Logs/DiagnosticReports/` whenever a process in our bundle faults —
synchronously, by the OS, with no cooperation from the crashing process. A next-launch
scanner reads those reports and forwards them. This is the only approach that catches
an in-process crash (the app is dead — nothing in-process can report it) without
embedding a native signal handler, and it reuses the entire v1a delivery path. The cost
is a one-launch delay and unsymbolicated frames, both acceptable per the goal.

## 4. Architecture

Everything hangs off v1a's `DiagnosticsService` and PostHog `$exception` pipeline.
Three new components in `packages/screen_recorder/lib/diagnostics/`, plus small
additions to two existing v1a types.

| Component | Role | State on disk | Gate |
|---|---|---|---|
| `PersistentCrumbStore` (new) | mirror breadcrumb ring + activity context to disk, scrubbed, throttled | `diagnostics/session.json` | `shareDiagnostics` |
| `NativeCrashScanner` (new) | scan `.ips` at startup, filter, parse, emit, advance watermark | `diagnostics/native_crash_watermark.json` | `shareDiagnostics` |
| `NativeCrashReport` (new) | parsed model of one `.ips` | — | — |
| `DiagnosticsService.captureNativeCrash` (v1a stub → real) | build + enqueue native `$exception` | (existing `diagnostics_queue.json`) | `shareDiagnostics` |
| `ExceptionEventBuilder.fromNative` (v1a stub → real) | `NativeCrashReport` + crumbs + meta → `$exception` | — | — |

The single `shareDiagnostics` toggle gates **all** native behaviour: persisting crumbs
to disk, scanning, parsing, and sending. Off ⇒ nothing is written, read, or sent.

### 4.1 `PersistentCrumbStore` (the crux)

This is what makes correlation survive a full-app crash. v1a keeps breadcrumbs in an
in-memory ring inside `AnalyticsService` (fed via `dropEvent`, collected regardless of
the analytics gate). That ring dies with the process, so an in-process crash would
otherwise leave the next-launch native event with no context.

`PersistentCrumbStore` mirrors that ring — plus a small "current activity" record — to
one file:

```
app-support/diagnostics/session.json
{
  "session_id": "<per-launch uuid, also attached to this session's diagnostics events>",
  "launched_at": "<iso8601>",
  "crumbs": [ /* rolling ~30, same content-free events v1a already drops */ ],
  "activity": { "op": "export", "preset": "1080p", "duration_s": 42 }  // scrubbed, or null
}
```

- **`crumbs`** are the exact events v1a's breadcrumb ring already holds — content-free
  product-event names + cheap props. The store subscribes to the same `dropEvent`
  feed and keeps the last ~30.
- **`activity`** is a small map set at operation boundaries (export start, recording
  start, transcribe start) and cleared at their end. It answers "what was in flight."
  Scrubbed through `PiiScrubber` on write (params can contain paths).
- **Writes are throttled** — debounced ~2s and coalesced, so a burst of crumbs is one
  write. Plus a **synchronous best-effort flush immediately before the highest-risk
  handoffs** — spawning a helper binary, starting ScreenCaptureKit capture — so a crash
  in those moments isn't lost inside the debounce window. Losing the last <2s of crumbs
  on an unflushed crash is acceptable.
- **Only written when `shareDiagnostics` is ON.** If the user won't send diagnostics we
  never put crumbs or activity on disk. Turning the toggle off deletes the file.

### 4.2 Clean-exit clears the file — the crash discriminator

On graceful app shutdown the store **deletes** `session.json`. Therefore on next launch:

- **File present** ⇒ the previous session terminated uncleanly (a crash).
- **File absent** ⇒ the previous session exited cleanly.

The scanner uses this to decide whether to attach the persisted crumb trail to a native
event. It attaches **only when the file survived** — i.e. only when the app itself
actually died mid-session. This elegantly resolves the two crash shapes without
double-attribution (see §5).

### 4.3 `NativeCrashScanner`

Runs once at startup, best-effort, **after first frame** (never blocks launch), only
when `shareDiagnostics` is ON.

1. **Scan** `~/Library/Logs/DiagnosticReports/` for `*.ips` (and legacy `*.crash`).
2. **Filter** to reports whose responsible/faulting process is ours: the app bundle id
   (`com.slipreel.app`) or a bundled-helper executable name (`ffmpeg`, `ffprobe`,
   `whisper-cli`). All other processes' reports are ignored.
3. **Watermark:** `diagnostics/native_crash_watermark.json` stores the newest forwarded
   report's timestamp plus a small seen-set of report filenames. Reports at/behind the
   watermark are skipped; the watermark advances after a successful emit. Makes rescans
   idempotent across launches.
4. **Parse** minimal fields (see §4.4). Defensive: missing fields degrade, an
   unparseable file is skipped (not fatal), the scan continues.
5. **Emit:** for each new report → `ExceptionEventBuilder.fromNative(report, crumbs,
   meta)` → `DiagnosticsService.captureNativeCrash` → `PostHogSink`. `crumbs` is the
   previous session's persisted trail **iff** `session.json` survived (§4.2), else empty.
6. After the scan, `PersistentCrumbStore` deletes any surviving `session.json` and
   starts a fresh session for the current launch.

### 4.4 `NativeCrashReport` (parsed model)

Modern `.ips` is a JSON header line followed by a JSON body. We extract:

- `signal` / `exception` — e.g. `SIGSEGV`, `EXC_BAD_ACCESS` (used as the event `type`).
- `faultingBinary` — responsible process / crashed image name.
- `frames` — crashed thread's top ~15 frames as `binary + offset` (unsymbolicated).
- `osVersion`, `appVersion` / helper version, `crashedAt` timestamp.

Legacy `.crash` (plain text) is parsed by a smaller fallback path for the same fields.

### 4.5 `ExceptionEventBuilder.fromNative` — event shape

Produces a PostHog `$exception` consistent with v1a's Dart events:

```jsonc
{
  "event": "$exception",
  "properties": {
    "$exception_list": [{
      "type": "SIGSEGV",                 // signal / exception
      "value": "<scrubbed one-line summary>",
      "mechanism": { "handled": false, "synthetic": false },  // same shape as v1a
      "stacktrace": {
        "type": "raw",
        "frames": [
          { "platform": "custom", "lang": "native", "resolved": false,
            "function": "ffmpeg", "instruction_addr": "0x1a2b+0x1234" }
          // ... top ~15
        ]
      }
    }],
    "exception_platform": "native",      // top-level marker (mechanism.type is unused)
    "$exception_fingerprint": "SIGSEGV|ffmpeg|<top-offset>",
    "session_id": "<previous session's per-launch id>",
    "breadcrumbs": [ /* previous session's crumbs, or [] */ ],
    "context": { /* previous session's activity, scrubbed, or absent */ },
    "source": "app", "platform": "macos", "app_version": "..."
  }
}
```

Frames carry `platform: 'custom'` + `lang: 'native'` + `resolved: false` (PostHog
requires platform+lang per frame; `resolved:false` marks them unsymbolicated). The
`lang: 'native'` frames plus the top-level `exception_platform: 'native'` are how a
native event is told apart from a Dart one — `mechanism` keeps v1a's `{handled,
synthetic}` shape unchanged.
Fingerprint = signal + faulting binary + top-frame offset, so recurrences of the same
native crash group into one issue.

## 5. End-to-end correlation flow

**In-process crash** (ScreenCaptureKit / Flutter engine):

1. Live session streams crumbs + `activity` to `session.json` (throttled).
2. App dies. macOS writes an `.ips`. `session.json` is never cleared.
3. Next launch: scanner finds the new ours-`.ips`, sees `session.json` survived → native
   `$exception` carries the parsed crash **plus** the previous crumb trail + activity →
   send → advance watermark → start fresh session.
4. PostHog: a grouped native issue whose event reads "user was exporting 1080p, last ~30
   steps, then SIGSEGV in ScreenCaptureKit."

**Subprocess helper crash** (ffmpeg / whisper):

1. App survives. v1a **already** fired a *handled* export/transcribe `$exception` with
   the live crumb trail.
2. App later exits cleanly → `session.json` deleted.
3. Next launch: scanner finds the helper `.ips`, `session.json` absent → native event
   stands alone (signal + helper frames), **no** stale trail attached.
4. Correlation in PostHog: the handled failure and the native crash share the same
   `session_id` and near timestamps — they line up without double-attributing crumbs.

## 6. Privacy & consent

- **One gate:** `shareDiagnostics` (v1a's "Send crash & error reports" toggle) governs
  persist-to-disk, scan, parse, and send. No new UI.
- **Scrubbing:** every field pulled from an `.ips`, plus `activity` params, passes
  through `PiiScrubber` before it can leave — home dir → `~`, all file paths redacted
  (the hardening shipped in v1a covers usernames embedded in report paths).
- **Data minimization:** only the §4.4 fields; the raw `.ips` is never uploaded.
- **Off means silent:** toggle off ⇒ no `session.json`, no scanning, no watermark
  writes, no sends; toggle off at runtime deletes any existing `session.json`.

## 7. Startup sequence (additions to v1a init)

v1a already installs global handlers and starts the three consumers. v1b adds, after
first frame and only when `shareDiagnostics` is ON:

1. Construct `PersistentCrumbStore`, subscribe it to the breadcrumb feed, read+hold any
   surviving `session.json` from the previous session, then (after the scan) reset it.
2. Run `NativeCrashScanner` best-effort: scan → filter → parse → emit new reports with
   the held crumbs → advance watermark.

Both are wrapped so any failure is swallowed (never blocks or crashes launch).

## 8. Testing

All headless — fixture-driven, no real crashes needed.

- **`NativeCrashReport` / parser:** fixture `.ips` (a real SIGSEGV report containing
  paths + a username), a legacy `.crash`, and a truncated/garbage file → assert parsed
  fields, scrubbed output, and that the garbage file is skipped without throwing.
- **`NativeCrashScanner`:** a directory of mixed reports (ours + another app's) → only
  ours are forwarded; watermark advances; a second scan forwards nothing new (idempotent).
- **`PersistentCrumbStore`:** throttled writes coalesce; clean-exit deletes the file;
  a survived file's crumbs attach to the emitted event; `shareDiagnostics` off writes
  nothing and deletes an existing file.
- **`ExceptionEventBuilder.fromNative`:** top-level `exception_platform: 'native'`,
  `mechanism` == `{handled:false, synthetic:false}`, per-frame `platform`/`lang:
  'native'`/`resolved:false`, stable fingerprint for the same signal+binary+offset.
- **Integration (fake sink):** survived-session `.ips` → event with crumbs+context;
  clean-exit `.ips` → event without crumbs.

## 9. Files

New (`packages/screen_recorder/lib/diagnostics/`):
- `persistent_crumb_store.dart`
- `native_crash_scanner.dart`
- `native_crash_report.dart` (+ parser)

Changed:
- `diagnostics_service.dart` — flesh out `captureNativeCrash`; attach a per-launch
  `session_id` to every diagnostics event (so v1a's handled Dart failures also carry
  it, enabling the §5 same-session correlation).
- `exception_event_builder.dart` — flesh out `fromNative`.
- `analytics_service.dart` / breadcrumb feed — tee `dropEvent` into the crumb store.
- `main.dart` — wire the store + scanner into the post-first-frame init.
- settings — no change (reuses the `shareDiagnostics` toggle).

New tests (`packages/screen_recorder/test/diagnostics/`):
- `native_crash_report_test.dart` + `.ips` / `.crash` fixtures
- `native_crash_scanner_test.dart`
- `persistent_crumb_store_test.dart`
- additions to `exception_event_builder_test.dart`

## 10. Rollout

- Ship behind the existing toggle; no migration, no schema change (native events reuse
  the `$exception` shape PostHog already groups).
- Validate live the same way v1a was: force a helper crash (kill `ffmpeg` mid-export
  with SIGSEGV) and an in-process crash, relaunch, confirm one grouped native issue each
  in PostHog with the expected `exception_platform: 'native'` / `lang: 'native'` frames
  and — for the in-process case — an attached crumb trail.

## 11. Known limitations

- **`.ips` format drift** across macOS versions — the parser is best-effort and
  defensive; a format it can't read is skipped, never fatal.
- **One-launch delay** — a native crash is reported at the *next* launch, not live.
- **Unsymbolicated** — frames are binary + offset; matches the "track & correlate" goal,
  not deep debugging. Symbolication is a possible v1c.
- **~2s crumb loss window** — crumbs dropped in the final unflushed debounce interval
  before an in-process crash are not persisted (mitigated by the pre-handoff sync flush).
