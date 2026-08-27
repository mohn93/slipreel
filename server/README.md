# Slipreel API

Node/TypeScript + Postgres service behind nginx at `https://api.slipreel.app`.
Owns accounts, Stripe checkout/webhooks, device seats, and Ed25519 entitlement
tokens. This package is the Phase 1 skeleton (config, DB, migrations, health).

## Requirements
- Node 22+
- Docker (for local Postgres)

## Setup
```bash
cp .env.example .env
npm install
npm run db:up          # starts Postgres 16 on localhost:5433 (dbs: slipreel, slipreel_test)
```

## Develop
```bash
npm run dev            # tsx watch, migrates on boot, serves /health
curl localhost:8080/health
```

## Test
DB-backed tests need `TEST_DATABASE_URL` (in `.env`). Load it inline:
```bash
env $(grep -v '^#' .env | xargs) npm test
```
Note: `npm run typecheck` covers `src/` only, not `test/`; the test files are
exercised by `npm test` (vitest) rather than the typecheck step.

## Migrations
Add `migrations/NNNN_<name>.sql` (forward-only; never edit an applied file).
Apply manually with `env $(grep -v '^#' .env | xargs) npm run migrate`; the server
also migrates on boot.

## Build & run
```bash
npm run build && node dist/server.js
```

## Deploy (VPS)
- App dir: `/opt/slipreel-api` (built `dist/` + `node_modules` + `migrations/`).
- Secrets: `/etc/slipreel-api.env` (root-owned, `0600`) with `NODE_ENV=production`,
  `PORT=8080`, `DATABASE_URL=...`, `LOG_LEVEL=info`.
- systemd: install `deploy/slipreel-api.service` to `/etc/systemd/system/`, then
  `systemctl daemon-reload && systemctl enable --now slipreel-api`.
- nginx: install `deploy/nginx-api.conf` to `/etc/nginx/sites-available/`, symlink
  into `sites-enabled/`, then `certbot --nginx -d api.slipreel.app` and
  `nginx -t && systemctl reload nginx`.
- Postgres: create the `slipreel` role + database on the box; point `DATABASE_URL`
  at it. Requires the `citext` extension (migration `0001` enables it) — migration
  `0001` runs `CREATE EXTENSION IF NOT EXISTS citext`, which needs a role with
  privilege to create extensions (superuser, or a role granted it) on first migrate.
- The app binds `127.0.0.1` by default (nginx reaches it locally). If you ever set
  `HOST=0.0.0.0`, add a firewall rule (`ufw deny 8080`) so only nginx/443 is public.

## Env vars
See `.env.example`. `DATABASE_URL` is required; `PORT` (8080) and `LOG_LEVEL`
(info) have defaults.

## Stripe (test mode)

All of this is test mode (`sk_test_…`). Nothing here touches live mode.

1. Put your test secret key in `server/.env` as `STRIPE_SECRET_KEY=sk_test_...`.
2. Create the products/prices (idempotent) and copy the printed ids into `.env`:
   ```bash
   env $(grep -v '^#' .env | xargs) npm run stripe:bootstrap
   ```
3. Forward webhooks to the local server and copy the `whsec_...` it prints into
   `.env` as `STRIPE_WEBHOOK_SECRET`:
   ```bash
   stripe listen --forward-to localhost:8080/v1/stripe/webhook
   ```
4. Start the server (`npm run dev`) — with the Stripe env set it enables
   `/v1/checkout`, `/v1/portal`, and `/v1/stripe/webhook`. Without it, the
   server logs "billing disabled" and serves only the base routes.
5. Exercise it:
   - Create a checkout session:
     ```bash
     curl -s localhost:8080/v1/checkout \
       -H 'content-type: application/json' \
       -d '{"email":"you@example.com","plan":"yearly"}'
     ```
     Open the returned `url`, pay with test card `4242 4242 4242 4242` (any
     future expiry / CVC). Decline testing: `4000 0000 0000 0002`.
   - Or drive the webhook directly:
     ```bash
     stripe trigger checkout.session.completed
     stripe trigger customer.subscription.deleted
     ```
   Then check the DB: `psql "$DATABASE_URL" -c 'select plan,status,updates_until,current_period_end from entitlements'`.

Notes: the webhook verifies Stripe's signature over the raw body and is
idempotent (re-delivered events are no-ops). `stripe login` (once) is required
before `stripe listen`/`stripe trigger`.

## Licensing (auth + entitlement tokens)

Passwordless. A user is authenticated by reusing their completed Stripe Checkout
session, or by a single-use magic link. An authenticated request to `/v1/token`
registers the device (2 seats) and returns an Ed25519-signed entitlement token
the desktop app verifies offline.

Setup (test/dev):
1. Generate the dedicated entitlement keypair and paste the two lines into `.env`:
   ```bash
   npm run gen:entitlement-keys
   ```
2. Start the server (`npm run dev`). With the keys set it enables the licensing
   routes; without them it logs "licensing disabled" and serves only the base +
   billing routes.

Endpoints:
- `POST /v1/auth/session-from-checkout` `{ checkout_session_id }` → sets a session cookie for the buyer.
- `POST /v1/auth/magic-link` `{ email }` → issues a single-use link (email delivery stubbed; in non-production the response includes `debug_token`). `POST /v1/auth/magic-link/verify` `{ token }` → sets a session cookie.
- `POST /v1/token` (session cookie) `{ fingerprint, device_name? }` → `{ token, refresh_token, device_id }`. A 3rd device → 409 `{ error: 'seat_limit', devices }`.
- `POST /v1/token/refresh` `{ refresh_token, device_id }` → `{ token }` (no cookie needed).
- `GET /v1/devices` / `DELETE /v1/devices/:id` (session cookie) → list / deactivate.
- `GET /v1/entitlement/public-key` → the PEM the app embeds to verify tokens.

Token claims: `sub, iss, iat, exp` (~14d), `plan` (subscription|onetime|free),
`export`, `status`, `updates_until`, `device_id`, `seat_limit`. The private key is
env-only; never commit it and never reuse the Sparkle key.

## Web flow (Phase 4a — backend)

The marketing site (`slipreel.app`) calls the API (`api.slipreel.app`) with credentials.
Backend support:
- **CORS** — `CORS_ORIGINS` (comma-separated) allows those origins with credentials.
- **Email** — magic links are sent via Resend when `RESEND_API_KEY` is set; otherwise
  they are logged and (non-production only) returned as `debug_token`. Verify the
  `slipreel.app` sender domain in Resend before real sends.
- **Single-use login** — `session-from-checkout` consumes the checkout session
  (a leaked `checkout_session_id` works at most once, within 30 minutes).
- **Device/state threading** — `POST /v1/checkout` accepts `device`, `device_name`,
  `state`; they ride in the Stripe session metadata and are returned by
  `session-from-checkout`. `POST /v1/auth/magic-link` accepts the same and returns
  them from `.../verify`, so the web pages can mint a device token and deep-link back.
- **Rate limits** — magic-link 5/min, checkout + session-from-checkout 20/min per IP
  (in-memory; single-instance).

The static pages that drive this flow are Phase 4b.

## Local end-to-end (web flow)

Run the API and the static site together to click through the pages
(`site/pricing.html`, `success.html`, `login.html`, `account.html`):

1. Boot the API with local-friendly config in `server/.env` (test mode):
   - `CORS_ORIGINS=http://localhost:4173`
   - Stripe test keys + price ids (`npm run stripe:bootstrap`), entitlement keys
     (`npm run gen:entitlement-keys`), and optionally `RESEND_API_KEY`.
   - Then `npm run dev`.
2. Serve the site on the origin you allowed:
   ```bash
   npx --yes serve site -l 4173      # or: (cd site && python3 -m http.server 4173)
   ```
3. The pages auto-resolve the API base from the hostname: `slipreel.app` -> `https://api.slipreel.app`,
   otherwise `http://<host>:8080`. To point at a different local API, add
   `<meta name="slipreel-api-base" content="http://localhost:8080">` to the page `<head>`
   for local testing only (do not commit it).
4. Open `http://localhost:4173/pricing.html`, pay with Stripe test card
   `4242 4242 4242 4242`, and follow the redirect back to `/success.html`.

Deploy: `scripts/deploy-site.sh` rsyncs the whole `site/` tree (new pages ship
automatically). Serve clean URLs (`/pricing`, `/success`, `/login`, `/account`)
with `server/deploy/nginx-site.conf` (a `try_files $uri $uri.html` rule).
