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
  at it. Requires the `citext` extension (migration `0001` enables it).

## Env vars
See `.env.example`. `DATABASE_URL` is required; `PORT` (8080) and `LOG_LEVEL`
(info) have defaults.
