# Release rollout — 9 September 2026

The user explicitly approved the live API/site deployment, migration 0008,
publication of app 1.0.13 after CI, and restoration of original signed downloads
1.0.0–1.0.9. The earlier approval-review block was resolved by that approval.

## Source and release

- PR: https://github.com/mohn93/slipreel/pull/109 — merged.
- Tested candidate: b219db1b90a36e721079cd8959bb18d61c9c5a93.
- Candidate CI: https://github.com/mohn93/slipreel/actions/runs/34326358962 — passed all jobs.
- Merge commit / v1.0.13 tag: 63a12458c517342c3eb3a2f0a649ac57b9975a72.
- Release pipeline: https://github.com/mohn93/slipreel/actions/runs/34327219268 — passed all checks, signing, notarization and deployment.

- Published release: https://github.com/mohn93/slipreel/releases/tag/v1.0.13.
- Backup follow-up CI: https://github.com/mohn93/slipreel/actions/runs/34328392721 — all jobs passed.
- Changelog and GitHub release notes published; canonical public changelog matches
  the local SHA256. API readiness remains 200 after app publication.

## Live API, website and billing

- Reviewed API and matching website deployed to 185.203.116.117. Caddy remains
  the proxy; service slipreel-api runs Node 22.23.2 from /opt/slipreel-api.
- Deployed server Git tree: 93590b830dd7001055c970b30503761a33a0dad7.
- Migration 0008 applied during coordinated cutover. Old authentication credentials
  invalidated; customers must sign in again.
- Public /ready returns 200. Anonymous checkout and checkout completion return 401.
- Public checkout/auth JavaScript hashes match reviewed source. Sensitive pages
  exclude analytics. Guide, downloads and changelog return 200.
- Live Stripe webhook retains its URL, signing secret, API version and prior events;
  five settlement/refund/dispute event types added and verified. See
  stripe-rollout-2026-09-09.json for the nonsecret event inventory.
- Configured live prices verified: USD 9 monthly, legacy USD 89 yearly, USD 69 one-time.
- No successful historical payments, subscriptions or active one-time entitlements
  existed at preflight, so no legacy purchase reconciliation was needed.
- One explicitly authorized sign-in email was accepted by the live API. The user
  opened it and confirmed successful account sign-in. No real purchase or charge
  was made by this task.

## Backup and recovery preparation

- Protected backup: /var/backups/slipreel/20260909T074302Z, including database,
  API, website and private service configuration. A final database dump was taken
  after stopping the API immediately before migration.
- Backup restored into isolated database slipreel_restore_20260909t074302z;
  restore and migration rehearsal passed. Signing-key compatibility and staged
  API readiness were checked against that clone.
- Previous API directory retained as /opt/slipreel-api-before-61c816ad.
- A live rollback was not performed. Do not restore vulnerable authentication
  routes or invalidated credentials; use a database-compatible secure build.

## Historical downloads

All ten original signed releases 1.0.0–1.0.9 restored: 1,426,205,819 bytes.
Each matches its published appcast length and Ed25519 signature, with SHA256
verified on the origin before and after publication. All ten canonical public
URLs returned 200 with exact lengths. See archive-restoration-2026-09-09.json.
Temporary archive staging removed; existing 1.0.10–1.0.12 artifacts preserved.

## Published installer verification

All 14 independent artifact checks passed; see release-1.0.13-verification.json.
The canonical public appcast lists 1.0.13, build 1000013, length 162,281,084 bytes.
Sparkle Ed25519 verification passed. The downloaded file, GitHub asset digest,
origin versioned file, origin latest alias and streamed canonical public latest
all match SHA256:

`5823e38ff20b3ed1515161054baee75941e03f55e6b2ad49d9afa687d4923d6f`

DMG and app codesign, stapler and Gatekeeper checks passed. The app and bundled
ffmpeg, ffprobe and whisper-cli contain both x86_64 and arm64; helpers are signed
and have no Homebrew or /usr/local runtime links. Minimum macOS is 13.0. The app's
Sparkle public key matches the repository. The installer was mounted read-only,
inspected and unmounted; the user's installed app was not replaced or launched.

## Remaining verification

- Real paid purchase/receipt/refund/dispute flow and the complete installed-app
  Intel/Apple Silicon/macOS matrix were not performed.
- Origin has approximately 61 GB free; the restored archive occupies 1.8 GB.
  Netdata is healthy and service auto-restart is enabled, but no explicit Slipreel
  readiness alert or off-host database backup was verified. The user approved
  daily local backups; the timer is installed and the first 40,592-byte dump passed
  both archive and full-content validation. A real restore into a new disposable
  database also passed migration and referential-integrity checks; that database
  was removed afterward. It retains 14 UTC dates, running daily
  at 03:15 UTC plus up to 15 minutes of randomized delay. See
  daily-backup-verification-2026-09-09.json and PR 110. Off-host backup destination and
  uptime alert delivery still need selection or external-provider verification.
- Prior analytics credential retention/access has not been inspected; no connected
  PostHog management capability is available in this session.

The pre-existing Podfile.lock modification and unrelated strategy document remain
untouched and excluded from task commits.
