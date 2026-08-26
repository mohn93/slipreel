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
