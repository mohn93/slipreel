# Release hardening deployment runbook

This is the current deployment checklist for the September 2026 security and
recording-safety changes. The older Phase 7 document is historical setup context,
not evidence of current live configuration. Production rollout evidence is recorded in
[the dated rollout report](../reviews/rollout-status-2026-09-09.md).

## Release order and compatibility

1. Run the shared CI workflow on the exact candidate commit. It checks the
   Flutter app/engine/platform suites, website constraints, and API typecheck and
   database tests against disposable Postgres. Never point TEST_DATABASE_URL at
   production: the test helper drops the public schema.
2. Back up the production database and verify a restore into an isolated database.
   Record the currently running server build, environment variable *names*, and
   proxy/service configuration. The live API presented Caddy headers during review;
   do not replace that deployment with the historical nginx template by assumption.
3. Reconcile historical Stripe purchases before enabling reversal handling for
   existing one-time renewals. Old entitlement rows retained only the latest
   payment intent and update ceiling; a complete purchase ledger cannot be inferred
   from them. Follow server/README.md for migration and reconciliation details.
4. Deploy the new API and database migrations, then the matching website promptly.
   The old website's unauthenticated checkout will receive an authentication error
   against the new API; use a short maintenance window or atomic site/API rollout.
   Do not roll back to the vulnerable authentication routes to avoid that error.
5. The security migration invalidates existing browser sessions and device refresh
   credentials. Customers must verify their email and sign in again. Existing
   signed offline tokens can remain usable until their expiry (up to 14 days).
   Device records are retained so the same Mac can rotate its credentials rather
   than spending a new seat. Verify existing-device and two-device behavior.
6. Build/sign/notarize the new macOS release only after required checks succeed.
   The former public 1.0.12 binary does not receive source fixes until users
   install 1.0.13 or a later build. Inspect code signing, notarization, Sparkle signature,
   both architectures, and actual bundled ffmpeg/ffprobe/whisper helpers again.

## Approved billing policy

- Full refund: revoke that purchase's grant; unrelated valid purchases remain.
- Partial refund: retain access.
- Open dispute: suspend the affected purchase; restore after a merchant win, revoke after a merchant loss.
- Past-due subscriptions: seven-day grace; terminal unpaid/canceled subscriptions
  have no continuing access.
- Both license types: online token renewal at least every 14 days. Revocation
  takes effect on refresh, or when the previously signed token expires offline.

Ensure Stripe webhook registration includes delayed settlement, subscription,
refund and dispute events used by the current handler. Confirm live product and
price IDs from configuration and the Stripe Dashboard; never use old runbook
placeholder amounts. Verify receipt and magic-link email delivery with the
configured verified sending domain. Production must fail startup when required
billing/signing/email configuration is missing or invalid.

## Downloads and updates

The release workflow now retains all versioned DMGs. Provision enough storage and
monitor free space; never silently prune a customer's covered version. Back up
signed artifacts or mirror them into durable object storage. The public downloads
page lists available releases from the appcast and checks availability. Restore
missing historical enclosures from original signed GitHub release artifacts,
verify their existing Sparkle signatures, and publish them at the exact original
URLs. Do not rebuild an old version under the same signed URL.

Use `python3 scripts/prepare-download-archive.py --output /tmp/slipreel-archive`
for a read-only inventory. Add `--download` to stage missing originals from GitHub,
or `--version 1.0.0 --download` for a single release. The tool verifies length and
Ed25519 signature against the published appcast and checked-in public key before
moving a file into the staging folder. It never uploads. The rollout restored all original signed versions 1.0.0–1.0.9 and verified their
canonical public URLs; see the dated archive restoration evidence.

Automatic Sparkle checks/installations are disabled before native plugin startup.
Settings exposes manual checks and warns customers without an active subscription
about the one-time update ceiling, linking to earlier downloads. This prevents an
automatic offer from bypassing the compatibility explanation. Test an existing
installation with previously persisted automatic-update preferences, not only a
clean install. A future license-filtered update feed can restore automatic checks.

## Security operations

Review PostHog events/replays and retention for previously captured authentication
URLs or app-return links. Restrict access, remove affected records according to the
account's retention controls, and assess any required customer notification from
actual exposure evidence. The repair excludes credential/account/checkout pages,
disables replay, and scrubs sensitive parameters in other events. No analytics
records were inspected or deleted by this task.

Configure readiness/uptime and error alerts against the deployed service, verify
webhook retry visibility, and test backup restoration. Never paste secrets into
reports or commands that enter shared logs.

## Final release evidence still required

- Final configuration purchase: verified email, correct price/mode, delayed webhook,
  activation, cancellation/retry preserving desktop context, second device and
  seat-limit handling, receipt, full/partial refund and dispute policy.
- Installed app on Intel and Apple Silicon, macOS 13 and current macOS: permissions,
  full-screen/window/region/device capture, mic/system/camera sync, pause/sleep,
  long recording and low disk, export/cancel, crash recovery, reopened edits.
- Old-version update installation, one-time ceiling warning, and covered-version
  download/install/export. Confirm site availability checks do not hide the last
  eligible release because its archive file is missing.
- Restore a backup and rehearse rollback to a database-compatible secure build.
  Keep migrations forward-only. Do not restore old session/refresh credentials or
  reintroduce checkout-as-authentication during a rollback.

Record dates, candidate commit/build, results, and responsible operator. Synthetic
tests do not substitute for live payment/email delivery or the hardware matrix.
