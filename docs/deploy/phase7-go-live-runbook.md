# Phase 7 — Go-Live Runbook (test-mode end-to-end)

What this achieves: take the licensing system (PR #65, Phases 1-6) from "all green in test/dev" to a **running deployment** you can click through end-to-end — buy in the browser, the token deep-links back into the app, export unlocks. Everything here stays in **Stripe test mode** (no real charges); §14 covers the later switch to live.

This is a runbook YOU execute against your VPS and accounts. It touches a production box, DNS, and third-party account settings, so the side-effectful steps (DNS records, TLS cert issuance, the Stripe Dashboard webhook, the Resend domain, placing secrets) are yours to perform — they are flagged `[you]`. Mechanical build/deploy steps are flagged `[run]`.

## Security ground rules (do not violate)

- Secrets — `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `ENTITLEMENT_ED25519_PRIVATE_KEY`, `RESEND_API_KEY`, `DATABASE_URL` — live ONLY in `/etc/slipreel-api.env` on the VPS (root-owned, mode `0600`). Never commit them, never paste them into chat or a PR, never echo them into shell history you keep. The systemd unit already sources them via `EnvironmentFile`.
- The entitlement **private key** never leaves the server. Only its 32-byte **public** half is baked into the app (safe to commit).
- The app talks to `api.slipreel.app` over HTTPS only. Do not run the API on a public HTTP port; nginx terminates TLS and proxies to `127.0.0.1:8080`.

## Prerequisites

- SSH access to the VPS `185.203.116.117` (the box already hosts `slipreel.app` + the Sparkle appcast/DMGs).
- DNS control for `slipreel.app`.
- A Stripe account in **test mode** (the "Becoming Ventures" test account; `acct_1U8gSqJa6q311aT7`). Test price IDs already exist (§7).
- A Resend account (for magic-link email).
- Node 22+ and Postgres on the VPS (§2).
- Repo checked out on the VPS (or a build artifact you rsync up). Server code is `server/`, ESM, `engines.node >= 22`.

Note on paths: the Flutter app lives under `packages/screen_recorder/` — the baked key and config files referenced in §10 are at `packages/screen_recorder/lib/licensing/`.

---

## 1. DNS `[you]`

Add an A record so the API has a hostname (the site already resolves):

```
api.slipreel.app.   A   185.203.116.117
```

Verify before continuing (TLS issuance in §5 needs it resolving):

```bash
dig +short api.slipreel.app    # -> 185.203.116.117
```

## 2. VPS: app dir, service user, Postgres `[you]`

On the VPS:

```bash
# Service user + app dir (matches server/deploy/slipreel-api.service)
sudo useradd --system --home /opt/slipreel-api --shell /usr/sbin/nologin slipreel-api || true
sudo mkdir -p /opt/slipreel-api
sudo chown slipreel-api:slipreel-api /opt/slipreel-api

# Node 22 (if not present) — via nodesource or your package manager of choice.
node --version    # must be >= 22

# Postgres: create a database + role for the API.
sudo -u postgres psql <<'SQL'
CREATE ROLE slipreel_api LOGIN PASSWORD 'CHANGE_ME_STRONG';
CREATE DATABASE slipreel OWNER slipreel_api;
SQL
```

Your `DATABASE_URL` will be `postgres://slipreel_api:CHANGE_ME_STRONG@127.0.0.1:5432/slipreel` (use the real password; it goes only in the env file in §3).

## 3. Generate the entitlement keypair + write the secrets file `[you]`

Generate the **production** Ed25519 entitlement keypair once (this is NOT the Sparkle key). From the repo `server/` dir on any trusted machine:

```bash
cd server
npm ci
npm run gen:entitlement-keys
```

It prints (base64 of PEM text):

```
ENTITLEMENT_ED25519_PRIVATE_KEY=...
ENTITLEMENT_ED25519_PUBLIC_KEY=...
```

Keep both lines. The private line goes into the server env file below; the public line is also used in §10 to bake into the app. **Save the public line somewhere you can retrieve in §10** — you need the exact same key that the server signs with, or the app will reject every token.

Create `/etc/slipreel-api.env` on the VPS (root-owned, `0600`). Fill every value; the file is the single source of secrets:

```bash
sudo install -m 0600 /dev/null /etc/slipreel-api.env
sudo tee /etc/slipreel-api.env >/dev/null <<'ENV'
NODE_ENV=production
PORT=8080
HOST=127.0.0.1
LOG_LEVEL=info

DATABASE_URL=postgres://slipreel_api:CHANGE_ME_STRONG@127.0.0.1:5432/slipreel

# Web origin(s) allowed to call the API with credentials (comma-separated).
CORS_ORIGINS=https://slipreel.app,https://www.slipreel.app

# Stripe (TEST mode). sk_test_... only for now.
STRIPE_SECRET_KEY=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...            # from §7, after creating the endpoint
STRIPE_PRICE_MONTHLY=price_1U8lMWJa6q311aT7GVrhrzrM
STRIPE_PRICE_YEARLY=price_1U8lMYJa6q311aT71vuov8ak
STRIPE_PRICE_ONETIME=price_1U8lMZJa6q311aT7YZbPvHMp
PUBLIC_SITE_URL=https://slipreel.app

# Entitlement signing (from `npm run gen:entitlement-keys`).
ENTITLEMENT_ED25519_PRIVATE_KEY=...
ENTITLEMENT_ED25519_PUBLIC_KEY=...
ENTITLEMENT_ISSUER=https://api.slipreel.app
ENTITLEMENT_TOKEN_TTL_DAYS=14

# Resend (from §8).
RESEND_API_KEY=re_...
RESEND_FROM=Slipreel <noreply@slipreel.app>
ENV
```

Gating detail that bites if you skip a var: the licensing routes AND `GET /v1/entitlement/public-key` are only registered when the token signer **and** Stripe **and** billing config all load. If any `STRIPE_*` or `ENTITLEMENT_ED25519_*` var is missing, those routes silently 404. Set them all before the smoke test in §11.

`ENTITLEMENT_ISSUER` must be exactly `https://api.slipreel.app` — the app's verifier hardcodes that issuer and rejects tokens with any other `iss`.

## 4. Build + install the API service `[run]`

Get the built server onto the box at `/opt/slipreel-api` (build locally and rsync `dist/` + `node_modules` + `package.json` + `migrations/`, or build on the box). Building on the box:

```bash
# On the VPS, from a checkout of the repo:
cd server
npm ci
npm run build           # tsc -> dist/
# Stage into the service dir (dist, node_modules, package.json, migrations):
sudo rsync -rlt --delete dist/ /opt/slipreel-api/dist/
sudo rsync -rlt node_modules/ /opt/slipreel-api/node_modules/
sudo cp package.json /opt/slipreel-api/
sudo rsync -rlt migrations/ /opt/slipreel-api/migrations/
sudo chown -R slipreel-api:slipreel-api /opt/slipreel-api
```

Install the systemd unit (shipped in the repo):

```bash
sudo cp server/deploy/slipreel-api.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now slipreel-api
sudo systemctl status slipreel-api --no-pager
journalctl -u slipreel-api -n 50 --no-pager
```

The service runs `node /opt/slipreel-api/dist/server.js`, sources `/etc/slipreel-api.env`, and **runs migrations automatically on boot** (see §6). It binds `127.0.0.1:8080`.

## 5. nginx + TLS `[you]`

Install the two server blocks (shipped in the repo) and issue certs:

```bash
sudo cp server/deploy/nginx-api.conf  /etc/nginx/sites-available/api.slipreel.app
sudo cp server/deploy/nginx-site.conf /etc/nginx/sites-available/slipreel.app
sudo ln -sf /etc/nginx/sites-available/api.slipreel.app  /etc/nginx/sites-enabled/
sudo ln -sf /etc/nginx/sites-available/slipreel.app      /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# TLS (certbot inserts the 443 blocks + HTTP->HTTPS redirects):
sudo certbot --nginx -d api.slipreel.app
sudo certbot --nginx -d slipreel.app -d www.slipreel.app
```

`nginx-api.conf` proxies `api.slipreel.app` -> `127.0.0.1:8080` and forwards the raw body (needed for Stripe signature verification — do not add body-rewriting). `nginx-site.conf` serves `/var/www/slipreel` with `try_files $uri $uri.html $uri/ =404` so `/pricing`, `/success`, `/login`, `/account` resolve to their `.html` files. The site webroot is shared with the Sparkle appcast/DMGs — never point rsync `--delete` at it (the site deploy script already avoids this).

## 6. Migrations `[run]`

The service migrates on every boot, so §4 already applied `0001..0006`. To run them manually (pre-flight or after adding a migration), from the server dir with `DATABASE_URL` exported:

```bash
cd server
DATABASE_URL='postgres://slipreel_api:...@127.0.0.1:5432/slipreel' npm run migrate
# -> "Applied: ..." or "Already up to date."
```

Confirm the schema:

```bash
psql "$DATABASE_URL" -c '\dt'    # users, entitlements, devices, sessions, magic_links, ...
```

## 7. Stripe: prices + webhook `[you]`

Prices already exist in the test account (the IDs in §3). To (re)create them idempotently:

```bash
cd server
STRIPE_SECRET_KEY=sk_test_... npm run stripe:bootstrap
# prints STRIPE_PRICE_MONTHLY / STRIPE_PRICE_YEARLY / STRIPE_PRICE_ONETIME
```

Create the webhook endpoint in the **Stripe Dashboard (test mode)** -> Developers -> Webhooks -> Add endpoint:

- URL: `https://api.slipreel.app/v1/stripe/webhook`
- Events: `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`

Copy the endpoint's **Signing secret** (`whsec_...`) into `STRIPE_WEBHOOK_SECRET` in `/etc/slipreel-api.env`, then `sudo systemctl restart slipreel-api`.

(During local dev you'd use `stripe listen --forward-to localhost:8080/v1/stripe/webhook`; in production the Dashboard endpoint is the real source.)

## 8. Resend: sender domain + key `[you]`

In the Resend dashboard: add and **verify** the `slipreel.app` sender domain (add the DKIM/SPF DNS records it gives you). Create an API key. Put it in `RESEND_API_KEY` and set `RESEND_FROM` to a verified address (e.g. `Slipreel <noreply@slipreel.app>`). Restart the service.

Until the domain is verified you can test with Resend's `onboarding@resend.dev` sender, but production magic-link email needs your own verified domain. Without `RESEND_API_KEY` the server still works but only logs magic links instead of sending them.

## 9. Deploy the web pages `[run]`

From the repo root (the script rsyncs `site/` -> `deploy@185.203.116.117:/var/www/slipreel`, excluding `package.json`/tests, with no removal or permission flags):

```bash
scripts/deploy-site.sh
```

`site/assets/js/config.js` auto-targets `https://api.slipreel.app` when served from `slipreel.app`, so no per-deploy config is needed. Verify:

```bash
curl -sSI https://slipreel.app/pricing | head -1     # 200
curl -sS  https://slipreel.app/assets/js/config.js | head -20
```

## 10. Re-bake the production public key + release the app `[run]`

The checked-in `packages/screen_recorder/lib/licensing/entitlement_public_key.g.dart` holds a **throwaway** test key. Replace it with the raw 32 bytes of the **production** public key from §3.

Extract the 32 ints (uses the corrected decode: outer base64 -> PEM text -> inner base64 -> SPKI DER -> last 32 bytes). Put the production `ENTITLEMENT_ED25519_PUBLIC_KEY` value into `PK`:

```bash
PK='PASTE_THE_PRODUCTION_PUBLIC_KEY_BASE64' \
node -e 'const b=process.env.PK; if(!b){console.error("set PK");process.exit(1)} const pem=Buffer.from(b,"base64").toString("utf8"); const body=pem.replace(/-----[^-]+-----/g,"").replace(/\s+/g,""); const der=Buffer.from(body,"base64"); console.log(JSON.stringify([...der.subarray(der.length-32)]))'
```

Paste the resulting 32 integers into `kEntitlementPublicKey` in `packages/screen_recorder/lib/licensing/entitlement_public_key.g.dart` (replacing the current bytes). Also set the real ship date in `build_release_date.g.dart` if this build is the public release (it drives the one-time version ceiling).

Sanity-check the baked key matches the server before shipping: the app's verifier must accept a token the live server mints. Quick check that the served key equals what you baked (both reduce to the same 32 bytes):

```bash
curl -sS https://api.slipreel.app/v1/entitlement/public-key   # PEM; its last-32-of-DER must equal your baked ints
```

Build + notarize the release (targets production automatically — `LicensingConfig` defaults to `api.slipreel.app` / `slipreel.app`, so **no `--dart-define` is needed** for a release build):

```bash
NOTARY_PROFILE=slipreel-notary scripts/release-macos.sh <version>
```

Commit the re-baked key + release-date change (public key only — safe to commit).

## 11. Smoke tests `[run]`

```bash
# API up + DB reachable:
curl -sS https://api.slipreel.app/health                  # {"status":"ok","db":"up"}

# Entitlement key served (proves stripe+billing+signer all loaded):
curl -sS https://api.slipreel.app/v1/entitlement/public-key   # a PEM block

# Checkout session creates (test mode) — returns a Stripe URL:
curl -sS -X POST https://api.slipreel.app/v1/checkout \
  -H 'content-type: application/json' \
  -d '{"plan":"monthly","email":"you+test@example.com"}'      # {"url":"https://checkout.stripe.com/..."}
```

If `/v1/entitlement/public-key` 404s, a `STRIPE_*` or `ENTITLEMENT_*` var is missing (§3 gating note).

## 12. Full end-to-end walkthrough `[you]`

Install the released app (or run a `--release` build). Then, per the spec's §14 acceptance list, walk each path with Stripe test cards (`4242 4242 4242 4242` = success, `4000 0000 0000 0002` = decline; see the `stripe:test-cards` skill):

1. **Subscription unlock.** In the app, open a recording, click Export -> the paywall appears -> "Unlock export" opens `https://slipreel.app/pricing?device=...&state=...` in the browser -> pick monthly -> pay with the test card -> the success page mints a token and redirects to `slipreel://auth?...` -> the app's paywall auto-advances and export proceeds. Confirm the exported file is produced.
2. **One-time unlock.** Same, choosing the one-time plan. Confirm export works and `updates_until` is ~1 year out (check the `entitlements` row).
3. **Magic-link sign-in (second device / returning user).** On a second machine, click Export -> paywall -> "Already purchased? Sign in" -> `/login` -> enter the same email -> click the emailed link -> token deep-links back -> export unlocks. This is the 2nd of 2 seats.
4. **Seat limit.** A third device's `/v1/token` returns 409 with the device list; the web account page (`/account`) lets you deactivate one to free a seat, then the third activates.
5. **Cancel -> lock.** Cancel the subscription via the Stripe Customer Portal (`/account` -> Manage). The webhook flips the entitlement to canceled; within the token's 14-day `exp` (immediately on the next refresh/relaunch) export re-locks and the paywall shows the "subscription lapsed" copy.
6. **One-time version ceiling.** (Optional, hard to force live.) A one-time user on a build whose `buildReleaseDate` is after their `updates_until` sees the "renew your update year" paywall; their earlier build still exports.

Watch the server logs during the run: `journalctl -u slipreel-api -f`. Watch Stripe test-mode events in the Dashboard.

## 13. Rollback / troubleshooting

- **API won't start:** `journalctl -u slipreel-api -n 100`. Most common: a missing required var (`DATABASE_URL`) or Postgres not reachable. `/health` returns 503 with `db:down` if the DB query fails.
- **Licensing routes 404:** a `STRIPE_*` or `ENTITLEMENT_*` var is missing — the whole licensing/pubkey/token surface is gated on all three configs loading (§3).
- **App rejects every token:** the baked public key doesn't match the server's private key (re-do §10 against the same keypair as `/etc/slipreel-api.env`), or `ENTITLEMENT_ISSUER` isn't exactly `https://api.slipreel.app`.
- **Webhook signature failures:** `STRIPE_WEBHOOK_SECRET` doesn't match the Dashboard endpoint's signing secret, or a proxy rewrote the body (nginx as shipped does not).
- **Roll back a bad deploy:** keep the previous `dist/` (e.g. `sudo cp -r /opt/slipreel-api/dist /opt/slipreel-api/dist.bak` before staging); restore it and `sudo systemctl restart slipreel-api`. Migrations are forward-only — a rollback of code must stay compatible with the already-applied schema.

## 14. Switching to live Stripe (later, deliberate)

Only after the test-mode e2e is fully green:

1. In `/etc/slipreel-api.env`, swap `STRIPE_SECRET_KEY` to the **live** key (`sk_live_...`) and set live `STRIPE_PRICE_*` IDs. Run `npm run stripe:bootstrap` against the live key (it refuses non-`sk_test_` keys today — remove/adjust that guard deliberately, or create the live products in the Dashboard and paste their price IDs).
2. Create a **live** webhook endpoint (same URL/events) and put its `whsec_...` in `STRIPE_WEBHOOK_SECRET`.
3. Set final prices (test amounts $9 / $79 / $99 are placeholders).
4. Reconcile the marketing pricing on the landing page (it still shows a stale lifetime figure).
5. Restart the service; run one real low-value transaction to confirm, then refund it.

The entitlement keypair, DNS, TLS, Resend, and the app build do NOT change between test and live — only the Stripe keys/prices/webhook.

---

### Deferred cleanup (from the Phase 6 review — safe to do anytime)

- Add a `status: 'grace'` short-circuit test to `export_gate_test.dart`.
- Add widget coverage for the paywall's "Continue" button (subscription-lapsed / update-ceiling) and the error-alert branch.
- Gate the Export button's "Exporting..." spinner so it doesn't show while the paywall sheet is open (cosmetic).
