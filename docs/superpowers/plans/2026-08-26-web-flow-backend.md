# Web-Flow Backend Implementation Plan (Phase 4a)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `server/` API safely support a browser-driven purchase → login → token → deep-link flow: allow the `slipreel.app` origin (CORS), send real magic-link emails via Resend, make checkout-based login single-use, thread the app's device fingerprint + `state` nonce through both entry points, and rate-limit the auth/checkout endpoints.

**Architecture:** The marketing site (`slipreel.app`, static HTML) will call the API (`api.slipreel.app`) with credentials; since both share the registrable domain `slipreel.app` the session cookie is same-site, so we only need `@fastify/cors` (credentials + origin allowlist). Email is an injected `EmailSender` (Resend implementation via `fetch`), so tests never send mail and a keyless dev box degrades to log-only. Checkout-based login is hardened with a single-use consume (a `consumed_checkout_sessions` claim) on top of Phase 3's 30-min freshness window. The device fingerprint + `state` nonce ride through Stripe Checkout in session `metadata` (returned by `session-from-checkout`) and through magic links in new `magic_links` columns, so the web pages (Phase 4b) can mint an app token and deep-link back. Rate limiting is per-route via `@fastify/rate-limit`.

**Tech Stack:** Node 22, TypeScript (ESM, NodeNext), Fastify 5, `pg`, `zod`, `vitest` (all existing), plus `@fastify/cors` and `@fastify/rate-limit`. Resend is called over HTTP with `fetch` (no SDK dep).

**Spec:** [docs/superpowers/specs/2026-08-26-stripe-licensing-design.md](../specs/2026-08-26-stripe-licensing-design.md) (§8 auth flow / `state` nonce, §10 web pages, §12 security)

**Builds on:** Phases 1–3 (branch `feat/stripe-licensing`, PR #65). Migrations `0001`–`0004` exist; the next are `0005`/`0006`. The licensing surface (auth/tokens/devices) and billing (checkout/portal/webhook) are already implemented and injected via `buildApp`.

## Global Constraints

- **Location & style:** all code under `server/`; TypeScript + ESM (`.js` on relative imports), Node 22, Fastify 5. Follow Phase 1–3 patterns (injected deps, zod config, vitest DB tests with `testPool`/`resetDatabase`/`runMigrations`, the `makeLicensingApp` helper).
- **CORS:** allow only the configured origins (default `https://slipreel.app`) with credentials. Never `origin: true` / `*` with credentials.
- **Email:** injected `EmailSender`; secrets (Resend API key) env-only, never committed, never logged. Absent config → email disabled (log-only), and the request still succeeds.
- **Secrets:** `RESEND_API_KEY` and all secrets from environment only. `.env`/`server/.env` stay gitignored.
- **Single-use + freshness:** a completed Stripe Checkout session may establish a login at most once (consume), and only within Phase 3's 30-min freshness window.
- **State threading:** `state`/`device` are opaque pass-through values the API stores and returns verbatim; the API does NOT invent or validate them (the app generates `state` and verifies the echo in Phase 5).
- **Backward compatibility:** every new `buildApp` dep is optional; with none, behavior is unchanged and all existing tests pass. Rate-limit is registered `global: false` (opt-in per route), so unrelated routes/tests are unaffected. Each test builds a fresh app, so per-route limiters reset per test.
- **Migrations:** forward-only; next files are `0005_*.sql` then `0006_*.sql`. Never edit an applied migration.
- **DB tests:** `env $(grep -v '^#' server/.env | xargs) npm --prefix server test`. No test may hit the network (Resend included — inject a fake fetch/sender).
- **Git:** branch `feat/stripe-licensing`. Stage only files you created/changed.

## Scope note

This plan is the **backend half** of Phase 4. The static pages (`pricing`/`login`/`account`/`success`/`app-auth`) + nginx clean-URLs + deploy are **Phase 4b**, planned after this lands. This plan defines the contract those pages consume (endpoints, response fields, the `/login?token=` magic-link URL shape).

---

## File Structure

```
server/
  package.json               # + @fastify/cors, @fastify/rate-limit
  .env.example               # + CORS_ORIGINS, RESEND_API_KEY, RESEND_FROM
  migrations/
    0005_checkout_consume.sql # consumed_checkout_sessions
    0006_magic_link_ctx.sql   # magic_links + device_fingerprint/device_name/state
  src/
    config.ts                # + corsOrigins (CORS_ORIGINS)
    email/
      config.ts              # EmailConfig + loadEmailConfig
      sender.ts              # EmailSender interface
      resend.ts              # createResendSender (fetch -> Resend API)
    billing/
      config.ts              # + siteUrl on BillingConfig
    auth/
      magic_link.ts          # createMagicLink/consumeMagicLink extended w/ device/state
    routes/
      auth.ts                # session-from-checkout: consume + return metadata; rate limit
      magic-link.ts          # send email; accept + return device/state; rate limit
      billing.ts             # checkout: accept device/state -> session metadata; rate limit
    app.ts                   # register cors + rate-limit; + email dep
    server.ts                # wire corsOrigins + email sender (graceful)
  test/
    cors.test.ts
    resend-sender.test.ts
    magic-link.test.ts        # (extended) email send + device/state round-trip
    auth-routes.test.ts       # (extended) single-use consume + metadata return
    billing-routes.test.ts    # (extended) checkout metadata
    rate-limit.test.ts
    helpers/licensing.ts      # (extended) accept an injected email sender
  README.md                   # + web-flow / Resend / CORS notes
```

---

### Task 1: CORS for the slipreel.app origin

Allow the marketing site to call the API with credentials. Deliverable: a test proves an allowed origin gets `Access-Control-Allow-Origin` + credentials and a disallowed one does not.

**Files:**
- Modify: `server/package.json` (add `@fastify/cors`)
- Modify: `server/src/config.ts` (add `corsOrigins`)
- Modify: `server/src/app.ts` (register cors when origins provided; add dep)
- Modify: `server/src/server.ts` (pass `config.corsOrigins`)
- Create: `server/test/cors.test.ts`

**Interfaces:**
- Produces: `AppDeps.corsOrigins?: string[]`; `Config.corsOrigins: string[]`.

- [ ] **Step 1: Add dep** — add `"@fastify/cors": "^10.0.1"` to dependencies, then `npm --prefix server install`.

- [ ] **Step 2: Extend `server/src/config.ts`** — add to the zod schema, the `Config` type, and the return.

Schema field:
```ts
  CORS_ORIGINS: z.string().default('https://slipreel.app'),
```
Type field: `corsOrigins: string[];`
Return mapping:
```ts
    corsOrigins: e.CORS_ORIGINS.split(',').map((s) => s.trim()).filter(Boolean),
```

- [ ] **Step 3: Write the failing test `server/test/cors.test.ts`**

```ts
import { describe, it, expect, afterEach } from 'vitest';
import type { FastifyInstance } from 'fastify';
import pg from 'pg';
import { buildApp } from '../src/app.js';

// CORS doesn't need a DB; use a dummy pool that's never queried on these routes.
const pool = new pg.Pool({ connectionString: 'postgres://x:x@localhost:5432/x' });

describe('CORS', () => {
  let app: FastifyInstance;
  afterEach(async () => { if (app) await app.close(); });

  it('reflects an allowed origin with credentials on a preflight', async () => {
    app = buildApp({ pool, corsOrigins: ['https://slipreel.app'], logger: false });
    await app.ready();
    const res = await app.inject({
      method: 'OPTIONS', url: '/health',
      headers: { origin: 'https://slipreel.app', 'access-control-request-method': 'GET' },
    });
    expect(res.headers['access-control-allow-origin']).toBe('https://slipreel.app');
    expect(res.headers['access-control-allow-credentials']).toBe('true');
  });

  it('does not allow a disallowed origin', async () => {
    app = buildApp({ pool, corsOrigins: ['https://slipreel.app'], logger: false });
    await app.ready();
    const res = await app.inject({
      method: 'OPTIONS', url: '/health',
      headers: { origin: 'https://evil.example', 'access-control-request-method': 'GET' },
    });
    expect(res.headers['access-control-allow-origin']).toBeUndefined();
  });
});
```

- [ ] **Step 4: Run it — expect FAIL** (`corsOrigins` not accepted / no CORS headers)

Run: `npm --prefix server test -- cors`

- [ ] **Step 5: Modify `server/src/app.ts`** — import, dep, registration.

Add import at top: `import cors from '@fastify/cors';`
Add to `AppDeps`: `corsOrigins?: string[];`
Immediately AFTER `const app = Fastify({...})` and BEFORE `app.decorate('pool', ...)`, add:
```ts
  if (deps.corsOrigins && deps.corsOrigins.length > 0) {
    app.register(cors, { origin: deps.corsOrigins, credentials: true });
  }
```

- [ ] **Step 6: Run it — expect PASS (2 tests)**

Run: `npm --prefix server test -- cors`

- [ ] **Step 7: Wire `server/src/server.ts`** — pass `corsOrigins: config.corsOrigins` into the `buildApp({ ... })` call (add the one property; leave the rest).

- [ ] **Step 8: Full suite + typecheck**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`
Expected: green (existing tests unaffected — they pass no `corsOrigins`).

- [ ] **Step 9: Commit**

```bash
git add server/package.json server/package-lock.json server/src/config.ts \
  server/src/app.ts server/src/server.ts server/test/cors.test.ts
git commit -m "feat(server): CORS for the slipreel.app origin with credentials"
```

---

### Task 2: Resend email sender (interface + impl + config)

A thin, injectable email sender backed by Resend's HTTP API. Deliverable: a unit test (fake `fetch`) proves the request shape and error handling — no network.

**Files:**
- Create: `server/src/email/sender.ts`
- Create: `server/src/email/config.ts`
- Create: `server/src/email/resend.ts`
- Create: `server/test/resend-sender.test.ts`

**Interfaces:**
- Produces:
  - `type EmailSender = { sendMagicLink(to: string, link: string): Promise<void> }`
  - `type EmailConfig = { apiKey: string; from: string }`; `loadEmailConfig(env?): EmailConfig` (throws if `RESEND_API_KEY` missing; `RESEND_FROM` defaults to `Slipreel <noreply@slipreel.app>`)
  - `createResendSender(config: EmailConfig, fetchImpl?: typeof fetch): EmailSender`

- [ ] **Step 1: Implement `server/src/email/sender.ts`**

```ts
/** Transactional email sender. Injected into the app so tests never send mail. */
export type EmailSender = {
  sendMagicLink(to: string, link: string): Promise<void>;
};
```

- [ ] **Step 2: Implement `server/src/email/config.ts`**

```ts
import { z } from 'zod';

const schema = z.object({
  RESEND_API_KEY: z.string().min(1, 'RESEND_API_KEY is required'),
  RESEND_FROM: z.string().min(1).default('Slipreel <noreply@slipreel.app>'),
});

export type EmailConfig = { apiKey: string; from: string };

export function loadEmailConfig(env: NodeJS.ProcessEnv = process.env): EmailConfig {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
      .join('; ');
    throw new Error(`Invalid email configuration: ${issues}`);
  }
  return { apiKey: parsed.data.RESEND_API_KEY, from: parsed.data.RESEND_FROM };
}
```

- [ ] **Step 3: Write the failing test `server/test/resend-sender.test.ts`**

```ts
import { describe, it, expect, vi } from 'vitest';
import { createResendSender } from '../src/email/resend.js';

const config = { apiKey: 'test_key', from: 'Slipreel <noreply@slipreel.app>' };

describe('createResendSender', () => {
  it('POSTs a well-formed request to Resend', async () => {
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ id: 'e1' }), { status: 200 }));
    const sender = createResendSender(config, fetchImpl as unknown as typeof fetch);
    await sender.sendMagicLink('u@example.com', 'https://slipreel.app/login?token=abc');

    expect(fetchImpl).toHaveBeenCalledTimes(1);
    const [url, init] = fetchImpl.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.resend.com/emails');
    expect(init.method).toBe('POST');
    const headers = init.headers as Record<string, string>;
    expect(headers.Authorization).toBe('Bearer test_key');
    expect(headers['Content-Type']).toBe('application/json');
    const body = JSON.parse(init.body as string);
    expect(body.from).toBe(config.from);
    expect(body.to).toEqual(['u@example.com']);
    expect(typeof body.subject).toBe('string');
    expect(body.html).toContain('https://slipreel.app/login?token=abc');
  });

  it('throws when Resend returns a non-2xx', async () => {
    const fetchImpl = vi.fn(async () => new Response('nope', { status: 422 }));
    const sender = createResendSender(config, fetchImpl as unknown as typeof fetch);
    await expect(sender.sendMagicLink('u@example.com', 'https://x/y')).rejects.toThrow(/resend/i);
  });
});
```

- [ ] **Step 4: Run it — expect FAIL**

Run: `npm --prefix server test -- resend-sender`

- [ ] **Step 5: Implement `server/src/email/resend.ts`**

```ts
import type { EmailConfig } from './config.js';
import type { EmailSender } from './sender.js';

/** Resend-backed sender. `fetchImpl` is injectable so tests never hit the network. */
export function createResendSender(
  config: EmailConfig,
  fetchImpl: typeof fetch = fetch,
): EmailSender {
  return {
    async sendMagicLink(to, link) {
      const res = await fetchImpl('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${config.apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          from: config.from,
          to: [to],
          subject: 'Your Slipreel sign-in link',
          html: `<p>Click to sign in to Slipreel:</p><p><a href="${link}">${link}</a></p>`
            + `<p>This link expires in 15 minutes. If you didn't request it, ignore this email.</p>`,
        }),
      });
      if (!res.ok) {
        throw new Error(`resend send failed: ${res.status}`);
      }
    },
  };
}
```

- [ ] **Step 6: Run it — expect PASS (2 tests)**

Run: `npm --prefix server test -- resend-sender`

- [ ] **Step 7: Typecheck, then commit**

Run: `npm --prefix server run typecheck`

```bash
git add server/src/email/sender.ts server/src/email/config.ts server/src/email/resend.ts \
  server/test/resend-sender.test.ts
git commit -m "feat(server): injectable Resend email sender"
```

---

### Task 3: Send the magic-link email

Wire the injected sender into the magic-link request and expose the site base URL to build the link. Deliverable: a test proves the sender is called with the right recipient and a `/login?token=` link, and the request still succeeds (and returns `debug_token` in test) with or without email configured.

**Files:**
- Modify: `server/src/billing/config.ts` (add `siteUrl`)
- Modify: `server/src/app.ts` (add `email` dep + `app.email` decoration)
- Modify: `server/src/routes/magic-link.ts` (send email)
- Modify: `server/src/server.ts` (build the sender when configured)
- Modify: `server/test/helpers/licensing.ts` (inject an optional email sender)
- Modify: `server/test/magic-link.test.ts` (assert the send)

**Interfaces:**
- Consumes: `EmailSender` (Task 2), `loadEmailConfig`/`createResendSender`.
- Produces: `AppDeps.email?: EmailSender`; `FastifyInstance.email?: EmailSender`; `BillingConfig.siteUrl: string`; `makeLicensingApp(pool, { session?, email? })`.

- [ ] **Step 1: Add `siteUrl` to `server/src/billing/config.ts`** — add `siteUrl: string;` to `BillingConfig` and set `siteUrl: site,` in the returned object (the `site` const already exists there).

- [ ] **Step 2: Extend `server/src/app.ts`** — add the optional email dep + decoration.

Add to the module augmentation block (alongside `pool`/`stripe`/`billing`/`tokenSigner`): `email?: EmailSender;`
Add import: `import type { EmailSender } from './email/sender.js';`
Add to `AppDeps`: `email?: EmailSender;`
Inside the licensing guard (`if (deps.tokenSigner && deps.stripe && deps.billing) { ... }`), as the FIRST line of the block, add:
```ts
    if (deps.email) app.decorate('email', deps.email);
```
(`app.email` is thus present only when an email sender was provided.)

- [ ] **Step 3: Modify `server/src/routes/magic-link.ts`** — send the email in the request handler. In the `if (user) { ... }` branch, AFTER `const { token } = await createMagicLink(app.pool, user.id);`, replace the log line with:

```ts
      const link = `${app.billing.siteUrl}/login?token=${token}`;
      if (app.email) {
        try {
          await app.email.sendMagicLink(parsed.data.email, link);
        } catch (err) {
          app.log.error({ err }, 'magic link email send failed');
        }
      } else {
        app.log.info({ email: parsed.data.email }, 'magic link issued (email delivery not configured)');
      }
      if (process.env.NODE_ENV !== 'production') {
        return reply.send({ sent: true, debug_token: token });
      }
```
(Keep the outer `return reply.send({ sent: true });` for production / unknown-email.)

- [ ] **Step 4: Extend `server/test/helpers/licensing.ts`** — accept an injected email sender.

Change the `makeLicensingApp` options type to `{ session?: unknown; email?: import('../../src/email/sender.js').EmailSender }` and pass `email: opts.email` into the `buildApp({ ... })` call. Return `email` in the result object too:
```ts
  const app = buildApp({ pool, stripe, billing, tokenSigner: signer, email: opts.email, logger: false });
```
and include `email: opts.email` in the returned object.

- [ ] **Step 5: Write the failing test additions in `server/test/magic-link.test.ts`**

Add a test (keep the existing 4):
```ts
  it('sends the magic-link email via the injected sender', async () => {
    const sent: Array<{ to: string; link: string }> = [];
    const email = { sendMagicLink: async (to: string, link: string) => { sent.push({ to, link }); } };
    const { app } = await makeLicensingApp(pool, { email });
    const res = await app.inject({ method: 'POST', url: '/v1/auth/magic-link', payload: { email: 'm@e.com' } });
    expect(res.statusCode).toBe(200);
    const token = res.json().debug_token as string;
    expect(sent).toHaveLength(1);
    expect(sent[0].to).toBe('m@e.com');
    expect(sent[0].link).toContain(`/login?token=${token}`);
    await app.close();
  });

  it('unknown email does not send', async () => {
    const sent: string[] = [];
    const email = { sendMagicLink: async (to: string) => { sent.push(to); } };
    const { app } = await makeLicensingApp(pool, { email });
    await app.inject({ method: 'POST', url: '/v1/auth/magic-link', payload: { email: 'nobody@e.com' } });
    expect(sent).toHaveLength(0);
    await app.close();
  });
```

- [ ] **Step 6: Run — expect the two new tests PASS (and the existing 4 still pass)**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- magic-link`

- [ ] **Step 7: Wire `server/src/server.ts`** — build the sender when configured. After the tokenSigner try/catch, add:

```ts
import { loadEmailConfig } from './email/config.js';
import { createResendSender } from './email/resend.js';
```
```ts
let email;
try {
  email = createResendSender(loadEmailConfig());
} catch (err) {
  email = undefined;
}
```
Pass `email` into `buildApp({ ... })`. After the "licensing disabled" warn, add:
```ts
if (!email) app.log.warn('email delivery disabled: RESEND_API_KEY not set (magic links log only)');
```

- [ ] **Step 8: Full suite + typecheck, then commit**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`

```bash
git add server/src/billing/config.ts server/src/app.ts server/src/routes/magic-link.ts \
  server/src/server.ts server/test/helpers/licensing.ts server/test/magic-link.test.ts
git commit -m "feat(server): send magic-link emails via Resend"
```

---

### Task 4: Single-use checkout-based login

Make `session-from-checkout` consume the checkout session so a leaked id can log in at most once. Deliverable: a test proves the second login attempt with the same session id returns 409.

**Files:**
- Create: `server/migrations/0005_checkout_consume.sql`
- Modify: `server/src/routes/auth.ts`
- Modify: `server/test/auth-routes.test.ts`

**Interfaces:** none new (behavior change only).

- [ ] **Step 1: Write `server/migrations/0005_checkout_consume.sql`**

```sql
-- Records which completed Checkout sessions have already established a login,
-- so a leaked checkout_session_id cannot be replayed for a second session.
CREATE TABLE consumed_checkout_sessions (
  session_id  text PRIMARY KEY,
  consumed_at timestamptz NOT NULL DEFAULT now()
);
```

- [ ] **Step 2: Write the failing test — add to `server/test/auth-routes.test.ts`**

```ts
  it('is single-use: the same checkout session cannot log in twice', async () => {
    const now = Math.floor(Date.now() / 1000);
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_c', created: now } });
    const first = await app.inject({ method: 'POST', url: '/v1/auth/session-from-checkout', payload: { checkout_session_id: 'cs_once' } });
    expect(first.statusCode).toBe(200);
    const second = await app.inject({ method: 'POST', url: '/v1/auth/session-from-checkout', payload: { checkout_session_id: 'cs_once' } });
    expect(second.statusCode).toBe(409);
    await app.close();
  });
```
(Clear the table in `beforeEach` — add `await pool.query('DELETE FROM consumed_checkout_sessions');` alongside the existing deletes.)

- [ ] **Step 3: Run it — expect FAIL** (second call currently returns 200)

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- auth-routes`

- [ ] **Step 4: Modify `server/src/routes/auth.ts`** — claim the session before establishing login. In `session-from-checkout`, AFTER the freshness check and BEFORE resolving the customer, add:

```ts
    const claim = await app.pool.query(
      'INSERT INTO consumed_checkout_sessions (session_id) VALUES ($1) ON CONFLICT DO NOTHING RETURNING session_id',
      [parsed.data.checkout_session_id],
    );
    if (claim.rowCount === 0) {
      return reply.code(409).send({ error: 'checkout session already used' });
    }
```

- [ ] **Step 5: Run — expect PASS (the new test + the existing auth tests)**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- auth-routes`

- [ ] **Step 6: Full suite + typecheck, then commit**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`

```bash
git add server/migrations/0005_checkout_consume.sql server/src/routes/auth.ts server/test/auth-routes.test.ts
git commit -m "feat(server): single-use checkout-based login"
```

---

### Task 5: Thread device fingerprint + state through both entry points

Carry the app's `device`/`device_name`/`state` through Stripe Checkout metadata (returned by `session-from-checkout`) and through magic links (new columns). Deliverable: tests prove checkout stores the metadata, `session-from-checkout` returns it, and magic-link request→verify round-trips it.

**Files:**
- Create: `server/migrations/0006_magic_link_ctx.sql`
- Modify: `server/src/auth/magic_link.ts`
- Modify: `server/src/routes/billing.ts` (checkout accepts + stores metadata)
- Modify: `server/src/routes/auth.ts` (session-from-checkout returns metadata)
- Modify: `server/src/routes/magic-link.ts` (accept + return device/state)
- Modify: `server/test/billing-routes.test.ts`, `server/test/auth-routes.test.ts`, `server/test/magic-link.test.ts`

**Interfaces:**
- Produces:
  - `createMagicLink(pool, userId, ctx?, ttlMinutes?)` where `ctx?: { device?: string|null; deviceName?: string|null; state?: string|null }` — stores the columns.
  - `consumeMagicLink(pool, token)` now returns `{ userId: string; device: string|null; deviceName: string|null; state: string|null } | null`.
  - `session-from-checkout` response gains `device`, `device_name`, `state` (nullable).

- [ ] **Step 1: Write `server/migrations/0006_magic_link_ctx.sql`**

```sql
ALTER TABLE magic_links
  ADD COLUMN device_fingerprint text,
  ADD COLUMN device_name text,
  ADD COLUMN state text;
```

- [ ] **Step 2: Modify `server/src/auth/magic_link.ts`** — persist + return the context.

Replace `createMagicLink` and `consumeMagicLink` with:
```ts
import type pg from 'pg';
import { newId } from '../ids.js';
import { newSecretToken, hashToken } from './secret_token.js';

export type MagicLinkContext = {
  device?: string | null;
  deviceName?: string | null;
  state?: string | null;
};

export async function createMagicLink(
  pool: pg.Pool,
  userId: string,
  ctx: MagicLinkContext = {},
  ttlMinutes = 15,
): Promise<{ token: string }> {
  const { token, hash } = newSecretToken();
  const expiresAt = new Date(Date.now() + ttlMinutes * 60_000);
  await pool.query(
    `INSERT INTO magic_links (id, user_id, token_hash, expires_at, device_fingerprint, device_name, state)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [newId('mlk'), userId, hash, expiresAt, ctx.device ?? null, ctx.deviceName ?? null, ctx.state ?? null],
  );
  return { token };
}

export async function consumeMagicLink(
  pool: pg.Pool,
  token: string,
): Promise<{ userId: string; device: string | null; deviceName: string | null; state: string | null } | null> {
  const { rows } = await pool.query<{
    user_id: string; device_fingerprint: string | null; device_name: string | null; state: string | null;
  }>(
    `UPDATE magic_links SET consumed_at = now()
     WHERE token_hash = $1 AND consumed_at IS NULL AND expires_at > now()
     RETURNING user_id, device_fingerprint, device_name, state`,
    [hashToken(token)],
  );
  const r = rows[0];
  return r ? { userId: r.user_id, device: r.device_fingerprint, deviceName: r.device_name, state: r.state } : null;
}
```

- [ ] **Step 3: Modify `server/src/routes/billing.ts`** — checkout accepts + stores context.

Extend `checkoutBody`:
```ts
const checkoutBody = z.object({
  email: z.string().email(),
  plan: z.enum(['monthly', 'yearly', 'onetime']),
  device: z.string().optional(),
  device_name: z.string().optional(),
  state: z.string().optional(),
});
```
In the handler, build metadata (only defined keys) and pass it to `sessions.create`:
```ts
    const metadata: Record<string, string> = {};
    if (parsed.data.device) metadata.device = parsed.data.device;
    if (parsed.data.device_name) metadata.device_name = parsed.data.device_name;
    if (parsed.data.state) metadata.state = parsed.data.state;
    const session = await app.stripe.checkout.sessions.create({
      customer: stripeCustomerId,
      mode,
      line_items: [{ price, quantity: 1 }],
      success_url: app.billing.successUrl,
      cancel_url: app.billing.cancelUrl,
      metadata,
    });
```

- [ ] **Step 4: Modify `server/src/routes/auth.ts`** — return the metadata from `session-from-checkout`. Change the final success reply to:
```ts
    const md = (cs.metadata ?? {}) as Record<string, string | undefined>;
    return reply.send({
      user: { id: user.id, email: user.email },
      device: md.device ?? null,
      device_name: md.device_name ?? null,
      state: md.state ?? null,
    });
```

- [ ] **Step 5: Modify `server/src/routes/magic-link.ts`** — accept context on request, return it on verify.

Extend the request body schema:
```ts
const requestBody = z.object({
  email: z.string().email(),
  device: z.string().optional(),
  device_name: z.string().optional(),
  state: z.string().optional(),
});
```
Pass context into `createMagicLink`:
```ts
      const { token } = await createMagicLink(app.pool, user.id, {
        device: parsed.data.device ?? null,
        deviceName: parsed.data.device_name ?? null,
        state: parsed.data.state ?? null,
      });
```
In the verify handler, include the context in the response:
```ts
    return reply.send({
      user: rows[0] ? { id: rows[0].id, email: rows[0].email } : { id: consumed.userId },
      device: consumed.device,
      device_name: consumed.deviceName,
      state: consumed.state,
    });
```

- [ ] **Step 6: Write failing tests** (add to the three suites)

In `server/test/billing-routes.test.ts` (add a test — the fake stripe already records `calls.checkout`):
```ts
  it('checkout forwards device/state into the session metadata', async () => {
    const { stripe, calls } = fakeStripe();
    const app = await make(stripe);
    await app.inject({ method: 'POST', url: '/v1/checkout',
      payload: { email: 'g@example.com', plan: 'yearly', device: 'fp-1', device_name: 'Mac', state: 'nonce-1' } });
    expect(calls.checkout.metadata).toEqual({ device: 'fp-1', device_name: 'Mac', state: 'nonce-1' });
    await app.close();
  });
```

In `server/test/auth-routes.test.ts`:
```ts
  it('session-from-checkout returns the device/state from metadata', async () => {
    const now = Math.floor(Date.now() / 1000);
    const { app } = await makeLicensingApp(pool, { session: {
      status: 'complete', customer: 'cus_c', created: now,
      metadata: { device: 'fp-9', device_name: 'Air', state: 'nonce-9' },
    } });
    const res = await app.inject({ method: 'POST', url: '/v1/auth/session-from-checkout', payload: { checkout_session_id: 'cs_md' } });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ device: 'fp-9', device_name: 'Air', state: 'nonce-9' });
    await app.close();
  });
```

In `server/test/magic-link.test.ts`:
```ts
  it('round-trips device/state from request to verify', async () => {
    const { app } = await makeLicensingApp(pool);
    const req = await app.inject({ method: 'POST', url: '/v1/auth/magic-link',
      payload: { email: 'm@e.com', device: 'fp-7', device_name: 'Studio', state: 'nonce-7' } });
    const token = req.json().debug_token as string;
    const ver = await app.inject({ method: 'POST', url: '/v1/auth/magic-link/verify', payload: { token } });
    expect(ver.statusCode).toBe(200);
    expect(ver.json()).toMatchObject({ device: 'fp-7', device_name: 'Studio', state: 'nonce-7' });
    await app.close();
  });
```

- [ ] **Step 7: Run — expect FAIL then implement (Steps 1-5 done) then PASS**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- billing-routes auth-routes magic-link`
Expected: the three new tests pass and all prior tests in those suites still pass (existing magic-link tests call `createMagicLink` only via the route, and `consumeMagicLink`'s new fields default to null for links created without context).

- [ ] **Step 8: Full suite + typecheck, then commit**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`

```bash
git add server/migrations/0006_magic_link_ctx.sql server/src/auth/magic_link.ts \
  server/src/routes/billing.ts server/src/routes/auth.ts server/src/routes/magic-link.ts \
  server/test/billing-routes.test.ts server/test/auth-routes.test.ts server/test/magic-link.test.ts
git commit -m "feat(server): thread device/state through checkout and magic links"
```

---

### Task 6: Rate-limit the auth + checkout endpoints

Cap abuse of the unauthenticated endpoints. Deliverable: a test proves the magic-link request 429s past its limit.

**Files:**
- Modify: `server/package.json` (add `@fastify/rate-limit`)
- Modify: `server/src/app.ts` (register the plugin `global: false`)
- Modify: `server/src/routes/magic-link.ts`, `server/src/routes/auth.ts`, `server/src/routes/billing.ts` (per-route `config.rateLimit`)
- Create: `server/test/rate-limit.test.ts`

**Interfaces:** none new.

- [ ] **Step 1: Add dep** — add `"@fastify/rate-limit": "^10.2.1"`, then `npm --prefix server install`.

- [ ] **Step 2: Register in `server/src/app.ts`** — add the plugin near the CORS registration (top of `buildApp`, before routes), `global: false` so only opted-in routes are limited:

Add import: `import rateLimit from '@fastify/rate-limit';`
After the CORS block (still before `app.decorate('pool', ...)`), add:
```ts
  app.register(rateLimit, { global: false });
```

- [ ] **Step 3: Add per-route limits.** Add a `config.rateLimit` to these route registrations:

`server/src/routes/magic-link.ts` — the `POST /v1/auth/magic-link` route:
```ts
  app.post('/v1/auth/magic-link', { config: { rateLimit: { max: 5, timeWindow: '1 minute' } } }, async (req, reply) => {
```
`server/src/routes/auth.ts` — `POST /v1/auth/session-from-checkout`:
```ts
  app.post('/v1/auth/session-from-checkout', { config: { rateLimit: { max: 20, timeWindow: '1 minute' } } }, async (req, reply) => {
```
`server/src/routes/billing.ts` — `POST /v1/checkout`:
```ts
  app.post('/v1/checkout', { config: { rateLimit: { max: 20, timeWindow: '1 minute' } } }, async (req, reply) => {
```

- [ ] **Step 4: Write the failing test `server/test/rate-limit.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';

describe('rate limiting', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });

  it('429s the magic-link request past 5/min from one IP', async () => {
    const { app } = await makeLicensingApp(pool);
    const codes: number[] = [];
    for (let i = 0; i < 6; i++) {
      const res = await app.inject({
        method: 'POST', url: '/v1/auth/magic-link',
        remoteAddress: '203.0.113.7',
        payload: { email: `x${i}@e.com` },
      });
      codes.push(res.statusCode);
    }
    expect(codes.slice(0, 5).every((c) => c === 200)).toBe(true);
    expect(codes[5]).toBe(429);
    await app.close();
  });
});
```

- [ ] **Step 5: Run it — expect FAIL then PASS** once the plugin + config are in place.

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- rate-limit`

- [ ] **Step 6: Confirm no regressions.** The limits (5 / 20 / 20 per minute) are per-app-instance and each test builds a fresh app, so existing suites (which make far fewer calls per instance to these routes) are unaffected.

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add server/package.json server/package-lock.json server/src/app.ts \
  server/src/routes/magic-link.ts server/src/routes/auth.ts server/src/routes/billing.ts \
  server/test/rate-limit.test.ts
git commit -m "feat(server): rate-limit auth and checkout endpoints"
```

---

### Task 7: Env template + README + boot verification

Document the new env and verify a graceful boot. Deliverable: `.env.example` + README updated; the server still boots without CORS/email/keys.

**Files:**
- Modify: `server/.env.example`
- Modify: `server/README.md`

- [ ] **Step 1: Extend `server/.env.example`** — append:

```dotenv

# --- Web flow (Phase 4) ---
# Comma-separated origins allowed to call the API with credentials.
CORS_ORIGINS=https://slipreel.app
# Resend transactional email (magic links). Key from resend.com; never commit it.
# Sender domain must be verified in Resend (or use onboarding@resend.dev for initial testing).
RESEND_API_KEY=re_...
RESEND_FROM=Slipreel <noreply@slipreel.app>
```

- [ ] **Step 2: Extend `server/README.md`** — append a short "Web flow (Phase 4)" section:

````markdown
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
````

- [ ] **Step 3: Boot regression (no CORS/email/keys)** — build, then boot with only base env and confirm graceful warnings + health:

```bash
npm --prefix server run build
env NODE_ENV=development PORT=8080 HOST=127.0.0.1 LOG_LEVEL=info \
  DATABASE_URL="$(grep '^DATABASE_URL=' server/.env | cut -d= -f2-)" \
  node server/dist/server.js &
sleep 1
curl -s localhost:8080/health   # {"status":"ok","db":"up"}
kill %1
```
Expected: `/health` ok; logs include "billing disabled", "licensing disabled", and "email delivery disabled" warnings (no CORS/email/Stripe/entitlement env was set). Capture output.

- [ ] **Step 4: Final full suite + typecheck + build**

Run: `npm --prefix server run typecheck && npm --prefix server run build && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add server/.env.example server/README.md
git commit -m "docs(server): document web-flow env (CORS, Resend)"
```

---

## Self-Review

**Spec coverage (Phase 4a — the backend portion of §8/§10/§12):**
- CORS for the site origin → Task 1. Real magic-link email (Resend) → Tasks 2–3. Single-use checkout login (hardens the §12 replay concern, complements Phase 3's freshness) → Task 4. `state` nonce + device threading (spec §8 flow) → Task 5. Rate-limiting (spec §5 "rate-limited") → Task 6. Env/docs → Task 7.
- Out of scope (Phase 4b): the static `pricing`/`login`/`account`/`success`/`app-auth` pages, nginx clean-URLs, and the `slipreel://` deep-link redirect (the API now returns everything those pages need). Out of scope (later): server-side `state` validation (the app verifies the echo in Phase 5), Redis-backed rate limiting for multi-instance, refund/`invoice.*` handling.

**Placeholder scan:** No TBD/TODO. The Resend `from`/domain and API key are real env with documented setup; email is fully functional once the key is set and no-ops safely without it.

**Type consistency:** `EmailSender.sendMagicLink(to, link)` is identical across `sender.ts`, `resend.ts`, the route, the helper, and the tests. `BillingConfig.siteUrl` (added Task 3) is read in the magic-link route. `AppDeps` grows `corsOrigins?` (Task 1) + `email?` (Task 3), matched in `server.ts` and `makeLicensingApp`. `createMagicLink(pool, userId, ctx?, ttl?)` and `consumeMagicLink → { userId, device, deviceName, state }` (Task 5) match their route call sites. Checkout `metadata` keys (`device`/`device_name`/`state`) match what `session-from-checkout` reads back. Migrations `0005` (consumed_checkout_sessions) and `0006` (magic_links columns) match the queries in Tasks 4–5.

**Cross-task DB note:** route tests re-run migrations (0001–0006) after `resetDatabase`, so `consumed_checkout_sessions` and the new `magic_links` columns exist. `auth-routes.test.ts` gains a `DELETE FROM consumed_checkout_sessions` in `beforeEach`. Existing Phase 1–3 tests are unaffected: CORS/email register only when their deps are passed, and rate-limit is `global: false` + per-app-instance.

---

## Execution Handoff

Choose how to execute — see the offer in chat.
