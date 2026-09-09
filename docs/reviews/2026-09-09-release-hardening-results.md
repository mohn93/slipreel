# Release hardening results — 9 September 2026

The reviewed source issues are addressed, with regression coverage and cross-review
by three agents. PR 109 is merged; the live API, website, security migration and
Stripe webhook updates are deployed. Historical downloads are restored. App 1.0.13
is signed, notarized and published. See [the rollout report](rollout-status-2026-09-09.md)
for current production evidence and remaining validation limits.

## Findings addressed

| Review item | Implemented repair |
|---|---|
| 1. Checkout account takeover | Email-verified sign-in precedes checkout. Cookie identity determines the customer. Checkout completion requires an existing owned session and never authenticates by payment reference. Migration invalidates old sessions, magic links, and device refresh credentials. |
| 2. Export deletes source | MP4/GIF reject source aliases, including symlinks and hardlinks. Unique staging, ffprobe validation, cancellation checks, and atomic publication preserve both source and previous destination on failure. |
| 3. Recovery loses audio/project data | Explicit video/all-audio mapping and stream-count validation; camera fragments and first-frame timing survive crashes; device identity persists. Failed recovery retains originals. A marker-cleanup error cannot erase the committed recovery. |
| 4. Analytics credentials | Sensitive pages exclude analytics; credential parameters are removed from the address bar; remaining analytics events scrub URLs/attributes; replay disabled. Prior production analytics records still require operational review. |
| 5. Paid activation race | Completion reconciles fulfillment before token activation. Website polls bounded pending responses and offers retry without another purchase; terminal failures have distinct guidance. |
| 6. Unpaid one-time grant | Paid status and configured price/quantity verified. Async settlement supported. Payment-intent ledger prevents duplicate fulfillment across webhook and success-page paths. |
| 7. Out-of-order subscriptions | Subscription retrieval and writes serialized; current Stripe state reconciled rather than blindly applying stale payloads. |
| 8. Refunds/disputes/grace | Independent purchase grants and durable reversal state handle reversal-before-fulfillment, partial refunds, disputes, and finite grace. Historical aggregate grants require verified reconstruction before readiness. |
| 9. Concurrent seat bypass | Per-user transaction serializes registration and same-device credential rotation. |
| 10. Lost cancellation context | Server-owned flow reference retains plan/device/state. Authenticated recovery and login-first retries preserve it. Website-only success explains installation and app sign-in. |
| 11. Wrong GIF duration | Limits and estimates use edited timeline duration after cuts/speed changes. |
| 12. Clipboard pathname | Native macOS file pasteboard representation, with truthful attachment guidance and Reveal in Finder. |
| 13. Launch-only renewal | Periodic/resume/pre-export renewal, ten-second timeout, retry backoff, shared in-flight request, and serialized atomic credential storage. Sign-out and new sign-in nonces survive stale refresh responses. Expired paid licenses show verification/retry, not another purchase. Failed callback persistence is retryable. |
| 14. Permanent-version fallback | Future DMGs retained; public date-filtered download archive checks actual availability. Automatic updates disabled before Sparkle startup; manual update flow warns about compatibility and links to earlier versions. Original signed 1.0.0–1.0.9 restored and verified at their public URLs. |
| 15. Missing release gates | Reusable CI includes backend/Postgres, Flutter/site, native regressions, and release scripts. Release publication depends on those checks at the candidate commit. API source and maintenance scripts typechecked. |
| 16. Inaccurate landing promises | Local-media versus network activity clarified in copy/structured data. Manual caption generation and roughly 488MB initial model download disclosed. |

Also added Account access, real forms, keyboard pricing controls, duplicate-submit
protection, guide, changelog, release-note links, dated comparison sources, and
updated documentation. Production configuration fails startup when required
services are missing; `/ready` checks configuration/database and historical
purchase reconciliation. Node now requires 22.12 or later. Vitest/Vite and qs
were upgraded; clean installation and the full dependency audit pass.

## Approved policies

The user approved full-refund revocation of the affected purchase, continued
access for partial refunds, suspension during open disputes, seven-day past-due
grace, no continuing access for terminal unpaid/canceled subscriptions, and
14-day online token renewal for both license types. Offline revocation remains
bounded by the lifetime of previously issued tokens.

## Verification

| Check | Result |
|---|---|
| Integrated Flutter app suite | 1,069 passed, 14 skipped; later affected areas rerun below |
| Final recovery/licensing/paywall/settings selection | 114 passed |
| Final licensing selection after callback-retry addition | 87 passed |
| Complete rendering/export engine suite | 1,550 passed, 2 skipped |
| Backend, including concurrency, fulfillment and reconciliation | 102 passed across 24 files on isolated local Postgres |
| Website JavaScript | 38 passed |
| Native Swift writer/timing/geometry | 61 passed, including fragmented camera/timestamp regression |
| Actual macOS debug application build | Passed, including native file pasteboard channel |
| Static checks | App and engine analysis clean; API and maintenance-script typecheck/build passed |
| Dependency installation/audit | Clean `npm ci`; full production+development audit: zero vulnerabilities |
| Release/site tooling | Appcast/version/build-date tests; site lint/guards; deploy guards; workflow YAML parsing and whitespace checks passed |
| Local browser | 390px homepage/pricing/guide layouts, radio keyboard controls, Enter validation, one request under repeated Enter, cleaned credential URL/no sensitive-page analytics, checkout retry retaining plan/device/state |
| Historical downloads | All originals 1.0.0–1.0.9 match appcast length, Ed25519 signature and origin SHA256; canonical public URLs return 200 |
| Candidate GitHub CI | All Linux, macOS/native and Postgres jobs passed on b219db1b |
| Live backend and email | Readiness/health 200; migration 0008 recorded; nine webhook events verified; user confirmed authorized email sign-in works |

Counts are separate runs and overlap; do not add them into a unique-test total.
Browser checkout testing used local fixtures; no real payment was made. One
authorized production sign-in email was sent and the user confirmed it worked.
The prior review's unchanged platform-interface and macOS Dart channel suites
were not rerun just to inflate this report's coverage.

Full app/engine and final targeted logs are under
`/tmp/slipreel-release-review/hardening-*.log`. Final backend toolchain logs are
`/tmp/slipreel-backend-toolchain-{tests,ci,typecheck,build}.log` and
`/tmp/slipreel-backend-toolchain-audit.json`. The original review and evidence remain alongside this file.

## Rollout and remaining validation

[The rollout report](rollout-status-2026-09-09.md) records the live API/site
cutover, migration 0008, nine-event Stripe webhook, restored historical downloads,
verified email sign-in and backup setup. No legacy purchase reconstruction was
needed: the live account had no successful historical payments or paid grants.
Daily root-only database backups retain 14 UTC dates; the first dump passed an
actual isolated restore drill, including the migrated schema and relationships.

App 1.0.13 passed its complete release pipeline, including signing, notarization,
Gatekeeper assessment and publication. All 14 independent public artifact checks
passed: feed version/build/length, Sparkle signature, matching GitHub/origin/public
latest hashes, DMG/app notarization and Gatekeeper, universal app/helpers, signed
helpers and portable runtime links. The installer was inspected read-only and
unmounted without changing the user’s installed app.

Remaining checks require real financial transactions or additional hardware:

- Paid purchase, receipt, activation, cancellation, refund/dispute processing and
  older-version update/downgrade checks on the final live configuration.
- Installed-app Intel/Apple Silicon and macOS 13/current macOS matrix, including
  permissions, long recordings, low disk, synchronization, recovery and saved edits.
- Prior analytics credential retention/access review. No PostHog management
  connection was available; no analytics history was inspected or deleted.
- Off-host backups and readiness/backup-failure alert delivery. Netdata host
  monitoring exists, but application alert delivery was not verified.
- Operational rollback rehearsal to a database-compatible secure build. Backup
  restore drills passed; no live rollback was attempted. Never restore invalidated
  credentials or vulnerable checkout authentication.

The [deployment runbook](../deploy/release-hardening-runbook.md) and
[backend instructions](../../server/README.md) document the operating procedure.
The pre-existing app Podfile.lock change and unrelated strategy document were
preserved and excluded from task commits. No real financial transactions were
created by this task.
