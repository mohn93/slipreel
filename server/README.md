# Slipreel API

Node 22.12+/TypeScript, Fastify and Postgres service for verified email accounts,
Stripe purchases, two-device licensing and Ed25519 entitlement tokens.

## Local development and tests

Copy `.env.example` to `.env`, configure test-mode credentials, then run `npm ci`
and `npm run db:up`. `npm run dev` starts the server and applies migrations.
For tests, supply a disposable database explicitly:

```sh
TEST_DATABASE_URL=postgres://slipreel:slipreel@127.0.0.1:5433/slipreel_test npm test
npm run typecheck
npm run build
```

Tests **drop the public schema**. Never supply a production database URL. Test
files run serially because each initializes its own schema. `npm run typecheck` covers server source and maintenance scripts, including legacy reconciliation. Development may run
without billing/signing/email configuration; production fails startup if any is
missing or invalid. `/health` checks the database; `/ready` also requires all
customer-facing services to be configured. Readiness does not prove upstream
Stripe or email delivery is available.

## Authentication and checkout

- `POST /v1/auth/magic-link` accepts email, optional device/device_name/state,
  and optional `checkout_plan`, `checkout_session_id`, `checkout_flow`. New users
  receive verification links too. Non-production responses include debug tokens.
- `POST /v1/auth/magic-link/verify` consumes the token, verifies email ownership,
  creates a secure HttpOnly cookie, and returns the stored flow context.
- `POST /v1/checkout` requires a verified authenticated user. `plan` is `monthly`
  or `onetime`; yearly is retained for existing subscriptions. Posted email never
  selects the customer. Optional device context is stored server-side.
  Stripe Checkout enables promotion-code entry for both plans. Create an active,
  customer-facing promotion code linked to the coupon in the same Stripe mode
  (live or test) as checkout; a coupon ID alone cannot be entered by customers.
  After deploying this setting, start a new checkout to see the code field.
- Cancel redirects contain an opaque `flow`; authenticated
  `GET /v1/checkout-context/:id` restores its plan/device/state for its owner.
- `POST /v1/auth/session-from-checkout` is retained as a compatibility path name,
  but **never logs anyone in**. It requires a session and matching customer,
  verifies the settled purchase price, reconciles fulfillment, and returns device
  context. HTTP202 `payment_pending` is retryable; references are not consumed.
- `/v1/token` activates/rotates a device under a per-account transaction lock;
  `/v1/token/refresh` validates its refresh secret. `/v1/devices`, `/v1/entitlement`,
  `/v1/portal` and logout are scoped to the authenticated account.

## Stripe fulfillment and payment policy

Configure webhook delivery for `checkout.session.completed`,
`checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`,
`customer.subscription.created`, `customer.subscription.updated`,
`customer.subscription.deleted`, `charge.refunded`, `charge.dispute.created`, and
`charge.dispute.closed`. Failed asynchronous payments grant nothing and return terminal HTTP 402 payment_failed on completion. Webhooks are
signature-verified; event claims and entitlement writes commit together.

Only settled purchases of configured prices grant access. The payment-intent
ledger deduplicates success-page reconciliation and different webhook event IDs.
Subscription deliveries reconcile Stripe's current state under a lock. REST calls explicitly pin API version2025-02-24.acacia; webhook snapshots can use a different version because live objects are retrieved by ID.
`past_due` receives seven days of grace anchored to the invoice due/finalization time or billing-period start; repeated
notifications cannot extend it. `unpaid` and canceled subscriptions lose access.
Active subscriptions also require a future billing period end.

Full refunds revoke the corresponding purchase; partial refunds retain it. Open
disputes suspend that purchase; won disputes restore it and lost disputes revoke
it. Other independent one-time purchases remain valid. Subscription reversals
block the affected billing period; open disputes remain suspended until resolved.
Refund and dispute state is stored even if it arrives before checkout fulfillment.
Offline signed licenses last 14 days, so server-side revocation is effective on the
next successful refresh or token expiry, not immediately on an offline Mac.

## Deploying migration 0008

Deploy the API and login-first website together. The forward migration clears all
web sessions and outstanding magic links, and invalidates device refresh hashes.
Existing device rows remain so verifying email and signing in on the same Mac
rotates credentials without consuming another seat. Previously issued signed
licenses expire within their existing 14-day lifetime.

Back up the database first and reconcile legacy one-time purchase history from
Stripe before refund automation is enabled for those purchases. The old schema
stored only the latest payment-intent ID and a cumulative update ceiling. The
migration preserves that ceiling as a `legacy_until` grant, but cannot infer all
previous renewals. Replace legacy grants with the verified individual settled
purchases and their original purchase times, retaining the verified ceiling.
Run `npm run reconcile:legacy -- --user USER_ID` with the intended database and
Stripe environment to inspect a rollback-only proposal; rerun with `--apply` only
after reviewing the before/after ceiling and payment list. This reads all settled
checkout sessions for that customer, verifies prices and current refunds/disputes,
and refuses to erase any grant missing from the retrieved history. Add repeatable `--historical-price price_ID` flags for retired one-time prices
that you have verified belong to this product; current prices remain accepted.
Unknown historical products remain excluded. Synthetic `legacy_` placeholders
can be replaced only with explicit `--expected-current-until ISO_TIMESTAMP` and
`--expected-reconciled-until ISO_TIMESTAMP` matching both reviewed dry-run ceilings
(use `none` for a null ceiling). Known payment IDs must still all be covered;
placeholder approval never disables that coverage check. `/ready` returns 503 while any legacy aggregate remains, and refunds of a
legacy aggregate retry instead of incorrectly revoking earlier purchases. Do not invent purchase history from timestamps.

Use production-mode Stripe and email credentials, configure the signing key pair,
CORS origin, success/cancel/portal URLs, and monitor `/ready`. Validate a real email
round trip and a controlled settled checkout/activation before broad release.
Current reverse-proxy configuration must be checked on the actual host; templates
under `deploy/` are examples and do not describe every live hosting setup.

Migrations in `migrations/NNNN_name.sql` are forward-only and run at boot. Never
modify an already applied migration. Secrets belong in the host's protected
environment file, not in Git or logs.

## Daily local database backup

`deploy/slipreel-db-backup.mjs` creates a consistent PostgreSQL custom dump under
`/var/backups/slipreel` (root 0700, files 0600). The root-owned systemd service loads
`/etc/slipreel-api.env`, runs `pg_dump` as `slipreel-api` for peer authentication,
and passes connection settings through its environment rather than process
arguments. Credentials and raw PostgreSQL diagnostics are never logged.

The timer runs daily at 03:15 UTC plus up to 15 minutes of randomized delay and
catches up after downtime. Each UTC date has one file. Only after both archive
listing and full data extraction validate does atomic publication replace that
date's backup; retention removes this task's exact daily filenames older than the
14-day window. Other backups, including protected rollout snapshots, are untouched.
Failures exit nonzero and preserve previous completed dumps. Monitor the service's
failure state; an external notification channel is not configured by this setup.

Install the script as `/usr/local/libexec/slipreel-db-backup.mjs` and the matching
service/timer from `deploy/` into `/etc/systemd/system/`; create the root-only backup
directory before starting the unit. Run `systemctl daemon-reload`, then
`systemctl start slipreel-db-backup.service` and
`systemctl enable --now slipreel-db-backup.timer`. Check the initial service result
and `systemctl list-timers slipreel-db-backup.timer`.

These backups are local to the VPS and **do not protect against host or disk loss**.
An off-host destination and regular restore drills remain separate operational
responsibilities. The dated rollout evidence records the initial successful restore drill.
Validation reads the archive content but does not restore it into a live database.
For isolated fixture tests, run `node --test test/db-backup.test.mjs` with
`BACKUP_TEST_DATABASE_URL`, and optional `BACKUP_TEST_PG_DUMP` /
`BACKUP_TEST_PG_RESTORE` pointing to compatible PostgreSQL clients. Never use a
production database as the test fixture.

Backend CI runs these backup tests explicitly against its disposable Postgres16
service using matching PostgreSQL16 clients, after the API test suite.
