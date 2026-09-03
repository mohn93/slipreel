# Local build-time defines (PostHog)

The app reads its PostHog config from compile-time `--dart-define`s
(`SLIPREEL_POSTHOG_KEY`, `SLIPREEL_POSTHOG_HOST`). The key is the **write-only
public project key** — safe to ship in a binary, but kept out of source; CI
injects it at release time, and locally you point Flutter at a JSON file here.

## Setup (once)

`posthog.json` is git-ignored and already exists as a copy of the template —
just drop your real key in:

```
SLIPREEL_POSTHOG_KEY  →  your phc_… project key
```

(If it's missing, copy the template: `cp posthog.example.json posthog.json`.)

## Run

From `packages/screen_recorder/`:

```bash
flutter run -d macos --dart-define-from-file=dart_defines/posthog.json
```

Same flag works for `flutter build macos --dart-define-from-file=…`.

### Live Error Tracking smoke test against a local capture server

To inspect the outgoing `/batch/` payload without touching prod, point the host
at a local server and add the key there:

```json
{ "SLIPREEL_POSTHOG_KEY": "phc_smoketest", "SLIPREEL_POSTHOG_HOST": "http://localhost:8799" }
```

Save that as e.g. `posthog.local.json` (also git-ignored) and run with
`--dart-define-from-file=dart_defines/posthog.local.json`. Without a host
override, events go to the real PostHog project — use a test distinct_id or a
uniquely-named exception so you can find and delete the test issue afterward.

### IDE

VS Code / Cursor: add `"toolArgs": ["--dart-define-from-file=dart_defines/posthog.json"]`
to your launch configuration. JetBrains: add the same to "Additional run args".
