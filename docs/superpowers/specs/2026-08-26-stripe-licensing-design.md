# Stripe + Licensing / Export Paywall — Design

Date: 2026-08-26
Status: Draft for review
Branch: `feat/stripe-licensing`

## 1. Goal

Monetize Slipreel by gating **export** behind a paid entitlement, while everything
else (record, edit, zoom, captions, preview) stays free. Two ways to pay:

- **Subscription** — monthly or yearly; export unlocked on all versions while active.
- **One-time** — perpetual export unlock, including free app updates for 1 year;
  after that the license keeps working on already-entitled versions, and the user
  can optionally buy another year of update entitlement (perpetual-fallback model).

Build and validate everything in **Stripe test mode first**; go live later.

## 2. Entitlement rules (source of truth)

Every gate in the app derives from a single signed **entitlement token**. The rules:

| User state | Export unlocked? | Notes |
|---|---|---|
| Free (no purchase) | No | Full app minus export. Export click → paywall. |
| Subscription active | Yes | Any app version. |
| Subscription past-due (grace) | Yes | Until grace window ends, then locks. |
| Subscription canceled/lapsed | No | Reverts to free. |
| One-time, within update window | Yes | Any version released on/before `updates_until`. |
| One-time, past update window, on an in-window build | Yes | Their paid version keeps exporting forever. |
| One-time, past update window, on a newer build | No (soft) | Export shows "renew update year"; app not bricked. |

Interpretation of "no updates after 1 year" (one-time): the **export entitlement**
does not extend to app versions released after `updates_until`. This is the standard
perpetual-fallback meaning — you keep what you paid for, newer releases need a renewal.
See §11 for how this interacts with the Sparkle binary updater and why we do NOT
hard-block the binary update in v1.

## 3. Architecture

Three components:

1. **VPS API** (new) — Node/TypeScript + Postgres, systemd unit behind nginx on the
   existing `94.156.144.73` box, reachable at `https://api.slipreel.app`. Owns:
   accounts, Stripe Checkout + Customer Portal, Stripe webhooks, device/seat tracking,
   and **minting Ed25519-signed entitlement tokens**.
2. **Web (site/) additions** — a few pages served from the existing static site:
   pricing, login/signup, post-checkout success, and the `/app-auth` handoff page that
   deep-links the signed token back into the desktop app.
3. **Flutter macOS app** (`packages/screen_recorder`) — new `licensing` module:
   sign-in via browser + `slipreel://` deep link, local token cache (Keychain),
   offline verification, periodic recheck, and the **export gate**.

### Data flow — purchase → unlock

```
App "Unlock export"
  → opens browser at https://slipreel.app/pricing?device=<deviceId>&state=<nonce>
  → user logs in / signs up (VPS API, session cookie)
  → picks plan → Stripe Checkout (test mode)
  → Stripe webhook → VPS: create/activate subscription|license, record customer
  → success page /app-auth?state=<nonce>
     → calls VPS /v1/token (authed) → returns Ed25519-signed entitlement token
     → redirects to slipreel://auth?token=<jwt>&state=<nonce>
  → app receives deep link, verifies signature offline, caches token in Keychain
  → export unlocked
```

### Data flow — ongoing verification

- On launch (if online) and at most every 24h, the app calls
  `POST /v1/token/refresh` with its stored refresh credential + device id.
  A fresh signed token is returned reflecting current subscription/license state.
- **Offline grace:** export stays unlocked using the cached token until
  `now > token.exp`. Tokens are minted with `exp = now + 14 days`, so a canceled or
  refunded user loses export within ~14 days offline, immediately when online. Brief
  offline use is never punished.

## 4. Entitlement token format

Compact JWT, **EdDSA (Ed25519)**. A dedicated keypair — NOT the Sparkle update key.
Private key on the VPS (env/secret file, never in git); public key embedded in the app.

Claims:

```jsonc
{
  "sub": "usr_...",            // account id
  "iss": "https://api.slipreel.app",
  "iat": 1750000000,
  "exp": 1751209600,          // iat + 14d (offline grace ceiling)
  "plan": "subscription",     // "subscription" | "onetime" | "free"
  "export": true,             // convenience: is export entitled *at all*
  "status": "active",         // "active" | "grace" | "canceled"
  "updates_until": null,      // onetime only: ISO date; version-ceiling for export
  "device_id": "dev_...",     // bound to the activating device
  "seat_limit": 2
}
```

App-side gate logic (pseudocode):

```
canExport(token, appReleaseDate):
  if token == null || expired(token): return false
  if token.plan == "subscription": return token.status in {active, grace}
  if token.plan == "onetime":
     return appReleaseDate <= token.updates_until   // release date baked at build time
  return false
```

`appReleaseDate` is compiled into the app at build time (e.g. a generated Dart const
from the release pipeline) so the one-time version-ceiling check needs no network.

## 5. VPS API surface

Base: `https://api.slipreel.app`. JSON. Auth via HttpOnly session cookie (web) and a
device-scoped refresh token (app). Rate-limited; all Stripe secrets server-side only.

Auth / account (PASSWORDLESS — revised 2026-08-26; supersedes the earlier
email+password design. See the Phase 3 plan
docs/superpowers/plans/2026-08-26-entitlement-tokens-and-auth.md):
- `POST /v1/auth/session-from-checkout` — `{ checkout_session_id }`. Reuses a
  completed Stripe Checkout session to log the buyer in (no password); sets an
  HttpOnly session cookie.
- `POST /v1/auth/magic-link` — `{ email }`. Issues a single-use sign-in link
  (email delivery via a provider TBD; stubbed for the test phase).
  `POST /v1/auth/magic-link/verify` — `{ token }` → sets the session cookie.
- `POST /v1/auth/logout`.
- (No password signup/login/reset; `users.password_hash` stays nullable/unused.)

Purchase:
- `POST /v1/checkout` — body `{ price_id, device_id?, state? }` → creates Stripe
  Checkout Session (mode `subscription` or `payment`), returns `{ url }`.
- `POST /v1/portal` — Stripe Customer Portal session (manage/cancel sub, update card).
- `POST /v1/stripe/webhook` — Stripe events (signature-verified). See §7.

Entitlement / devices:
- `POST /v1/token` — authed; body `{ device_id, device_name }`. Registers/validates
  the device against `seat_limit`, mints the signed entitlement token + a refresh token.
- `POST /v1/token/refresh` — body `{ refresh_token, device_id }` → new signed token.
- `GET  /v1/devices` — list activated devices.
- `DELETE /v1/devices/:id` — deactivate a device (free a seat).

## 6. Database schema (Postgres)

```sql
users (
  id            text primary key,         -- usr_...
  email         citext unique not null,
  password_hash text not null,
  email_verified boolean not null default false,
  stripe_customer_id text unique,
  created_at    timestamptz not null default now()
);

-- One row per active paid relationship. plan drives entitlement.
entitlements (
  id            text primary key,         -- ent_...
  user_id       text not null references users(id),
  plan          text not null,            -- 'subscription' | 'onetime'
  status        text not null,            -- 'active' | 'grace' | 'canceled' | 'incomplete'
  stripe_subscription_id text,            -- subscription plan only
  stripe_payment_intent_id text,          -- onetime plan only
  current_period_end timestamptz,         -- subscription: renewal/expiry
  updates_until timestamptz,              -- onetime: version-ceiling date
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

devices (
  id            text primary key,         -- dev_...
  user_id       text not null references users(id),
  fingerprint   text not null,            -- stable hardware id hash from the app
  name          text,
  refresh_token_hash text not null,
  last_seen_at  timestamptz,
  created_at    timestamptz not null default now(),
  unique (user_id, fingerprint)
);

-- Idempotency for webhook processing.
processed_stripe_events (
  event_id text primary key,
  processed_at timestamptz not null default now()
);
```

Seat enforcement: `count(devices where user_id = ?)` must be `<= seat_limit` (2) before
minting a token for a new fingerprint; over the limit → 409 with the device list so the
app/web can prompt to deactivate one.

## 7. Stripe setup (test mode first)

Products (test mode):
- **Slipreel Pro — Subscription**
  - price `monthly` (recurring/month)
  - price `yearly` (recurring/year)
- **Slipreel Pro — One-time (1 year of updates)**
  - price `onetime` (one-time `payment`)
  - reuse the same product/price for update-year **renewals** (each purchase pushes
    `updates_until` forward by 1 year).

Prices/amounts are placeholders in test mode; final numbers set before go-live.

Checkout modes:
- Subscription → Checkout Session `mode: subscription`.
- One-time / renewal → Checkout Session `mode: payment`.

Webhook events handled (`/v1/stripe/webhook`, signature-verified, idempotent via
`processed_stripe_events`):
- `checkout.session.completed` — link `stripe_customer_id`; for `payment` mode create/
  extend the one-time entitlement (`updates_until = max(now, existing) + 1y`); for
  `subscription` mode create the subscription entitlement.
- `customer.subscription.created|updated` — sync `status` + `current_period_end`.
- `customer.subscription.deleted` — mark canceled.
- `invoice.paid` / `invoice.payment_failed` — move between `active` / `grace`.

Keys/secrets (all server-side, in the VPS env, never committed):
`STRIPE_SECRET_KEY` (test), `STRIPE_WEBHOOK_SECRET`, `ENTITLEMENT_ED25519_PRIVATE_KEY`.
The app ships only `ENTITLEMENT_ED25519_PUBLIC_KEY` and the publishable key is not
needed (Checkout is hosted).

## 8. Auth / activation flow (desktop)

1. App generates a stable **device fingerprint** (hashed hardware id) and a one-time
   `state` nonce; opens `https://slipreel.app/pricing?device=<fp>&state=<nonce>` via
   `url_launcher`.
2. User authenticates + (if needed) pays on the web. The `/app-auth` page, once the
   session is authed and entitled, calls `POST /v1/token` and redirects to
   `slipreel://auth?token=<jwt>&refresh=<rt>&device_id=<dev_...>&state=<nonce>`.
   (Revised 2026-08-27: `device_id` — the server-assigned `dev_...` id, distinct from
   the app's local hardware fingerprint — is included so the app can call
   `POST /v1/token/refresh {refresh_token, device_id}`. The Phase 4b web pages already
   emit it; the Phase 5b app requires all four params present and non-empty.)
3. The app receives the deep link (via `app_links`), checks `state` matches, verifies
   the JWT signature with the embedded public key, and stores `{token, refresh, device_id}`
   in the macOS Keychain (`flutter_secure_storage`).
4. `slipreel://` is registered as a `CFBundleURLTypes` scheme in the macOS `Info.plist`.

Sign-out clears the Keychain and calls `DELETE /v1/devices/:id` to free the seat.

## 9. Flutter app changes

New module `lib/licensing/`:
- `entitlement.dart` — the token model + `canExport(appReleaseDate)` logic.
- `entitlement_token_verifier.dart` — Ed25519 verify (via `cryptography` or `pointycastle`).
- `licensing_controller.dart` — Riverpod controller: loads cached token, exposes
  `entitlementProvider`, triggers refresh on launch/interval, handles the deep-link
  callback, sign-in/sign-out.
- `licensing_api.dart` — thin HTTP client for the VPS endpoints (uses `http`).
- `device_fingerprint.dart` — stable per-machine id.

Storage: add `flutter_secure_storage` (Keychain). Deep links: add `app_links`.
Release date: the release pipeline generates `lib/licensing/build_release_date.g.dart`
with a `const releaseDate` used by the one-time ceiling check.

Export gate (the actual paywall):
- In [playback_screen.dart](../../../packages/screen_recorder/lib/ui/screens/playback_screen.dart)
  `_export()` (~line 1801): before showing `ExportDialog`, read `entitlementProvider`;
  if not entitled, show the **paywall sheet** (new `lib/ui/paywall/`) instead and return.
- Defense in depth: `ExportController.run()` in
  [export_controller.dart](../../../packages/screen_recorder/lib/ui/screens/playback/export_controller.dart)
  also asserts entitlement and returns `ExportFailure` if absent, so no code path
  reaches the pipeline unpaid.

Paywall UI (`lib/ui/paywall/`): explains the two plans, "Unlock export" button that
launches the browser flow, and a "Restore / Sign in" affordance. Uses existing
`AppPalette` tokens and `AppAlerts` per project conventions.

## 10. Web (site/) additions

Served from the existing static `site/` (rsync pipeline unchanged). New pages/routes
backed by the VPS API:
- `/pricing` — plans + Checkout buttons (carries `device` + `state` through).
- `/login`, `/signup`, `/reset` — account.
- `/account` — link to Stripe Customer Portal, device list/deactivate.
- `/app-auth` — the deep-link handoff page (mint token, redirect to `slipreel://`).
- `/success`, `/cancel` — Checkout return pages.

These are dynamic enough that they may live as small server-rendered routes on the VPS
API (same Node service) rather than the static bundle; the marketing pages stay static.

## 11. Sparkle binary updater interaction (important nuance)

The app auto-updates through the `auto_updater` Flutter plugin
([updater_service.dart](../../../packages/screen_recorder/lib/update/updater_service.dart))
pointed at a **single static** `https://slipreel.app/appcast.xml`. That plugin does not
expose Sparkle's `SPUUpdaterDelegate`, so we cannot cheaply filter appcast items by
publish date per entitlement on the client.

**v1 decision:** do NOT hard-block binary updates. The app itself is free, so everyone
keeps receiving app updates. The "no updates after 1 year" promise is enforced purely as
an **export-entitlement version ceiling** (§2, §4): a lapsed one-time user who updates to
a newer build simply finds export locked on that build (with a clear "renew your update
year" prompt), while their previously entitled build keeps exporting. This is the correct
perpetual-fallback semantics and needs zero native updater changes.

**Optional later enhancement:** make the feed URL entitlement-aware
(`appcast.xml?channel=onetime-2026` or an authed feed) so the server can stop *offering*
newer binaries to lapsed one-time users. Deferred — not needed for correctness.

## 12. Security considerations

- Ed25519 entitlement key: private key only on the VPS (root-owned secret file / env),
  public key in the app. Compromise of the app binary never yields signing power.
- Tokens are short-lived (`exp = 14d`) and device-bound; refresh requires the
  server-stored refresh token.
- Webhooks: verify `Stripe-Signature`; idempotent via `processed_stripe_events`.
- Passwords: argon2id; email verification before entitlement mint.
- The client is inherently patchable (offline license threat model). Acceptable for
  indie scale; server-side truth (rechecks, seat limits, revocation) bounds abuse.
- Never place tokens/emails in URL query logs beyond the one-time deep-link handoff;
  the `state` nonce is single-use.

## 13. Test-environment setup (concrete, do first)

1. **Stripe test mode:** create the products/prices in §7 (via Stripe CLI or MCP once
   authorized). Capture the test `price_id`s.
2. **Local secrets:** `.env` (gitignored) with test `STRIPE_SECRET_KEY`,
   `STRIPE_WEBHOOK_SECRET` (from `stripe listen`), and a freshly generated
   `ENTITLEMENT_ED25519` keypair.
3. **Webhook forwarding:** `stripe listen --forward-to localhost:PORT/v1/stripe/webhook`
   during dev; a real Stripe webhook endpoint on `api.slipreel.app` for the deployed box.
4. **Test cards:** use Stripe's `4242 4242 4242 4242` (success), `4000...0002` (decline),
   etc. (see the `stripe:test-cards` skill).
5. **Local DB:** Postgres via Docker for dev; migrations checked in.
6. App points at `http://localhost:PORT` in debug (`--dart-define`), `api.slipreel.app`
   in release.

## 14. Build order (phases → each its own plan)

1. **VPS API skeleton** — Node/TS + Postgres, migrations, health check, systemd/nginx.
2. **Stripe test integration** — products, `/v1/checkout`, `/v1/portal`, webhook handler,
   entitlement sync. Verify with `stripe trigger` + test cards.
3. **Entitlement tokens** — Ed25519 keypair, `/v1/token` + `/v1/token/refresh`, device
   seat logic.
4. **Web pages** — pricing/login/account/app-auth handoff.
5. **Flutter licensing module** — deep-link scheme, secure storage, verifier, controller,
   refresh.
6. **Export gate + paywall UI** — wire the gate at `_export()` and `ExportController`,
   build the paywall sheet.
7. **End-to-end test-mode run-through** — purchase (sub + one-time) → unlock → export;
   cancel → lock after grace; second device → seat prompt.

## 15. Open questions to confirm at review

- **Domain:** OK to stand up `api.slipreel.app` (new DNS A record → the VPS) for the API?
- **Web auth pages on VPS vs static:** confirm the dynamic pages (login/account/app-auth)
  run as routes on the same Node service (recommended) rather than the static bundle.
- **Prices:** placeholder test amounts are fine for now; final numbers before go-live —
  any ballpark you want reflected in the test products?
- **Email delivery** (verification, receipts): use Stripe's built-in receipts + a
  transactional email provider (e.g. Postmark/SES) for verification/reset — confirm a
  provider, or defer email verification for the test phase.
