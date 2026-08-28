# Entitlement Tokens + Passwordless Auth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the `server/` API mint Ed25519-signed entitlement tokens for a passwordlessly-authenticated user, with device-seat enforcement — the identity + token half of the licensing system the Flutter app will consume.

**Architecture:** Passwordless auth (no passwords). A user is logged in either by reusing their just-completed Stripe Checkout session (`session-from-checkout`) or by a single-use magic link (email delivery stubbed until a provider is chosen). A DB-backed opaque session lives in an HttpOnly cookie. Authenticated requests to `POST /v1/token` register the calling device (2-seat limit) and mint an EdDSA JWT whose claims come from the user's *effective* entitlement (resolved from the `entitlements` rows). `POST /v1/token/refresh` re-mints from a device refresh token without a cookie. All secrets (Ed25519 private key) are env-only; the public key is served for the app to embed. The whole licensing surface is gated behind an optional `tokenSigner` dep in `buildApp`, exactly like Phase 2 gated billing — so keyless dev and all existing tests keep working.

**Tech Stack:** Node 22, TypeScript (ESM, NodeNext), Fastify 5, `pg`, `zod`, `vitest` (all existing), plus `jose` (EdDSA JWT sign/verify) and `@fastify/cookie` (session cookie).

**Spec:** [docs/superpowers/specs/2026-08-26-stripe-licensing-design.md](../specs/2026-08-26-stripe-licensing-design.md) (§4 token format, §5 entitlement/device endpoints, §8 auth flow)

**Builds on:** Phase 1 skeleton + Phase 2 Stripe integration (both on branch `feat/stripe-licensing`, PR #65). Migrations `0001`–`0003` exist; the next is `0004`.

## Global Constraints

- **Location & style:** all code under `server/`; TypeScript + ESM (`.js` on relative imports), Node 22, Fastify 5. Follow Phase 1/2 patterns exactly (injected deps, zod config, vitest DB tests with `testPool`/`resetDatabase`/`runMigrations`).
- **Passwordless:** NO passwords are built. `users.password_hash` stays nullable (Phase 2 migration 0002) and unused. Identity comes from checkout-session reuse and magic links.
- **Token format (spec §4):** EdDSA (Ed25519) JWT. Dedicated keypair, NOT the Sparkle key. Private key env-only; public key embeddable/served. Claims: `sub`, `iss`, `iat`, `exp` (= iat + TTL days, default 14), `plan` ∈ {subscription,onetime,free}, `export` (bool), `status` ∈ {active,grace,canceled,none}, `updates_until` (ISO string or null), `device_id`, `seat_limit`.
- **Seats:** `seat_limit = 2`. A 3rd distinct device fingerprint → HTTP 409 with the current device list.
- **Secrets:** Ed25519 private key and all secrets come from environment only, never committed. Magic-link tokens and session tokens are stored HASHED (sha256), never in plaintext.
- **Backward compatibility:** the licensing surface registers only when `buildApp` gets a `tokenSigner` (plus the already-required `stripe`+`billing`). With none, the app is exactly Phase 1/2 — existing tests and keyless `npm run dev` unaffected.
- **Migrations:** forward-only; the next file is `server/migrations/0004_auth.sql`. Never edit an applied migration.
- **DB tests:** run with `env $(grep -v '^#' server/.env | xargs) npm --prefix server test`. `server/.env` exists locally (DATABASE_URL/TEST_DATABASE_URL). No test may hit the network.
- **Git:** branch `feat/stripe-licensing`. Stage only files you created/changed.

## Deviations from spec (ruled for this plan)

- **Passwordless replaces password auth.** Spec §5/§8 describe email+password (argon2id) signup/login. Per an explicit product decision, Phase 3 is passwordless: `session-from-checkout` (reuse the paid Checkout session) + magic-link. No `POST /v1/auth/signup|login|password-reset`, no argon2id. `users.password_hash` remains nullable and unused. The spec's §5/§8 will be reconciled to passwordless.
- **Email delivery is stubbed.** No email provider is chosen yet, so `POST /v1/auth/magic-link` logs the link and, ONLY when `NODE_ENV !== 'production'`, returns the token in the response (`debug_token`) so the flow is testable now. Wiring a real provider (Postmark/SES) is a later task; production never returns the token.
- **Test price ids (Becoming Ventures test mode)** already created: monthly `price_1U8lMWJa6q311aT7GVrhrzrM`, yearly `price_1U8lMYJa6q311aT71vuov8ak`, one-time `price_1U8lMZJa6q311aT7YZbPvHMp`. These go in `server/.env` (Task 8), not committed.

---

## File Structure

```
server/
  package.json                  # + jose, @fastify/cookie
  .env.example                  # + ENTITLEMENT_* keys, real test price ids (comments)
  migrations/
    0004_auth.sql               # sessions + magic_links tables
  src/
    ids.ts                      # (existing) newId
    tokens/
      config.ts                 # TokenConfig + loadTokenConfig (base64 PEM env)
      signer.ts                 # createTokenSigner -> mint/verify (jose EdDSA)
    billing/
      effective_entitlement.ts  # resolveEffectiveEntitlement(pool, userId)
    auth/
      secret_token.ts           # newSecretToken() / hashToken()
      sessions.ts               # createSession/resolveSession/deleteSession
      cookie.ts                 # SESSION_COOKIE + set/clear helpers
      require_session.ts        # requireSession preHandler (req.userId)
      magic_link.ts             # createMagicLink/consumeMagicLink
      devices.ts                # registerDevice/refreshDevice + SEAT_LIMIT
    routes/
      auth.ts                   # POST /v1/auth/session-from-checkout, /logout
      magic-link.ts             # POST /v1/auth/magic-link, /magic-link/verify
      token.ts                  # POST /v1/token, /v1/token/refresh
      devices.ts                # GET /v1/devices, DELETE /v1/devices/:id
      entitlement-pubkey.ts     # GET /v1/entitlement/public-key
    app.ts                      # + tokenSigner dep; licensing guard registers cookie + routes
    server.ts                   # load token config -> signer -> buildApp (graceful if absent)
  scripts/
    gen-entitlement-keys.ts     # print a base64 Ed25519 keypair for env
  test/
    tokens.test.ts
    effective-entitlement.test.ts
    sessions.test.ts
    auth-routes.test.ts
    magic-link.test.ts
    token-routes.test.ts
    devices-routes.test.ts
    helpers/
      licensing.ts              # makeLicensingApp(pool, opts) + makeTestSigner()
  README.md                     # + Licensing (auth + tokens) section
```

---

### Task 1: Ed25519 token config + signer + keygen script

Adds `jose` and the token-signing core: config (base64-PEM env), an async signer factory with mint/verify, and a keygen CLI. Deliverable: a unit test mints and verifies a token round-trip against a freshly-generated keypair.

**Files:**
- Modify: `server/package.json` (add `jose`)
- Create: `server/src/tokens/config.ts`
- Create: `server/src/tokens/signer.ts`
- Create: `server/scripts/gen-entitlement-keys.ts`
- Create: `server/test/tokens.test.ts`

**Interfaces:**
- Produces:
  - `type TokenConfig = { privateKeyPem: string; publicKeyPem: string; issuer: string; ttlDays: number }`
  - `function loadTokenConfig(env?: NodeJS.ProcessEnv): TokenConfig` (decodes base64 PEM; throws if a required var is missing)
  - `type EntitlementClaims = { sub: string; plan: 'subscription'|'onetime'|'free'; export: boolean; status: 'active'|'grace'|'canceled'|'none'; updates_until: string | null; device_id: string; seat_limit: number }`
  - `type TokenSigner = { publicKeyPem: string; mint(claims: EntitlementClaims): Promise<string>; verify(jwt: string): Promise<import('jose').JWTPayload> }`
  - `function createTokenSigner(config: TokenConfig): Promise<TokenSigner>`

- [ ] **Step 1: Add `jose` to `server/package.json` dependencies**

Add (keep existing deps): `"jose": "^5.9.6"`. Then `npm --prefix server install`.

- [ ] **Step 2: Write the failing test `server/test/tokens.test.ts`**

```ts
import { describe, it, expect, beforeAll } from 'vitest';
import { generateKeyPair, exportPKCS8, exportSPKI } from 'jose';
import { loadTokenConfig } from '../src/tokens/config.js';
import { createTokenSigner, type EntitlementClaims } from '../src/tokens/signer.js';

async function keyEnv() {
  const { publicKey, privateKey } = await generateKeyPair('EdDSA', { crv: 'Ed25519', extractable: true });
  const priv = Buffer.from(await exportPKCS8(privateKey)).toString('base64');
  const pub = Buffer.from(await exportSPKI(publicKey)).toString('base64');
  return {
    ENTITLEMENT_ED25519_PRIVATE_KEY: priv,
    ENTITLEMENT_ED25519_PUBLIC_KEY: pub,
    ENTITLEMENT_ISSUER: 'https://api.slipreel.test',
    ENTITLEMENT_TOKEN_TTL_DAYS: '14',
  };
}

const baseClaims: EntitlementClaims = {
  sub: 'usr_1', plan: 'subscription', export: true, status: 'active',
  updates_until: null, device_id: 'dev_1', seat_limit: 2,
};

describe('token signer', () => {
  let signer: Awaited<ReturnType<typeof createTokenSigner>>;
  let issuer: string;

  beforeAll(async () => {
    const env = await keyEnv();
    issuer = env.ENTITLEMENT_ISSUER;
    signer = await createTokenSigner(loadTokenConfig(env));
  });

  it('mints and verifies a token with the expected claims', async () => {
    const jwt = await signer.mint(baseClaims);
    const payload = await signer.verify(jwt);
    expect(payload.sub).toBe('usr_1');
    expect(payload.iss).toBe(issuer);
    expect(payload.plan).toBe('subscription');
    expect(payload.export).toBe(true);
    expect(payload.device_id).toBe('dev_1');
    expect(payload.seat_limit).toBe(2);
    // exp is ~14 days out.
    const days = ((payload.exp as number) - (payload.iat as number)) / 86400;
    expect(days).toBeCloseTo(14, 0);
  });

  it('rejects a tampered token', async () => {
    const jwt = await signer.mint(baseClaims);
    const tampered = jwt.slice(0, -3) + (jwt.endsWith('AAA') ? 'BBB' : 'AAA');
    await expect(signer.verify(tampered)).rejects.toBeDefined();
  });

  it('rejects a token signed by a different key', async () => {
    const other = await createTokenSigner(loadTokenConfig(await keyEnv()));
    const jwt = await other.mint(baseClaims);
    await expect(signer.verify(jwt)).rejects.toBeDefined();
  });

  it('loadTokenConfig throws when the private key is missing', () => {
    expect(() => loadTokenConfig({ ENTITLEMENT_ED25519_PUBLIC_KEY: 'x' })).toThrow(/ENTITLEMENT_ED25519_PRIVATE_KEY/);
  });
});
```

- [ ] **Step 3: Run it — expect FAIL** (`cannot import ../src/tokens/config.js`)

Run: `npm --prefix server test -- tokens`

- [ ] **Step 4: Implement `server/src/tokens/config.ts`**

```ts
import { z } from 'zod';

const schema = z.object({
  ENTITLEMENT_ED25519_PRIVATE_KEY: z.string().min(1, 'ENTITLEMENT_ED25519_PRIVATE_KEY is required'),
  ENTITLEMENT_ED25519_PUBLIC_KEY: z.string().min(1, 'ENTITLEMENT_ED25519_PUBLIC_KEY is required'),
  ENTITLEMENT_ISSUER: z.string().url().default('https://api.slipreel.app'),
  ENTITLEMENT_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(14),
});

export type TokenConfig = {
  privateKeyPem: string;
  publicKeyPem: string;
  issuer: string;
  ttlDays: number;
};

const fromB64 = (b64: string): string => Buffer.from(b64, 'base64').toString('utf8');

export function loadTokenConfig(env: NodeJS.ProcessEnv = process.env): TokenConfig {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
      .join('; ');
    throw new Error(`Invalid entitlement token configuration: ${issues}`);
  }
  const e = parsed.data;
  return {
    privateKeyPem: fromB64(e.ENTITLEMENT_ED25519_PRIVATE_KEY),
    publicKeyPem: fromB64(e.ENTITLEMENT_ED25519_PUBLIC_KEY),
    issuer: e.ENTITLEMENT_ISSUER,
    ttlDays: e.ENTITLEMENT_TOKEN_TTL_DAYS,
  };
}
```

- [ ] **Step 5: Implement `server/src/tokens/signer.ts`**

```ts
import { SignJWT, jwtVerify, importPKCS8, importSPKI, type JWTPayload } from 'jose';
import type { TokenConfig } from './config.js';

export type EntitlementClaims = {
  sub: string;
  plan: 'subscription' | 'onetime' | 'free';
  export: boolean;
  status: 'active' | 'grace' | 'canceled' | 'none';
  updates_until: string | null;
  device_id: string;
  seat_limit: number;
};

export type TokenSigner = {
  publicKeyPem: string;
  mint(claims: EntitlementClaims): Promise<string>;
  verify(jwt: string): Promise<JWTPayload>;
};

export async function createTokenSigner(config: TokenConfig): Promise<TokenSigner> {
  const privateKey = await importPKCS8(config.privateKeyPem, 'EdDSA');
  const publicKey = await importSPKI(config.publicKeyPem, 'EdDSA');

  return {
    publicKeyPem: config.publicKeyPem,
    async mint(claims) {
      const { sub, ...rest } = claims;
      return new SignJWT(rest as unknown as JWTPayload)
        .setProtectedHeader({ alg: 'EdDSA' })
        .setIssuedAt()
        .setIssuer(config.issuer)
        .setSubject(sub)
        .setExpirationTime(`${config.ttlDays}d`)
        .sign(privateKey);
    },
    async verify(jwt) {
      const { payload } = await jwtVerify(jwt, publicKey, { issuer: config.issuer });
      return payload;
    },
  };
}
```

- [ ] **Step 6: Run it — expect PASS (4 tests)**

Run: `npm --prefix server test -- tokens`

- [ ] **Step 7: Implement `server/scripts/gen-entitlement-keys.ts`**

```ts
/**
 * Generate a dedicated Ed25519 keypair for entitlement tokens (NOT the Sparkle
 * update key). Prints base64-encoded PEM lines to paste into server/.env.
 *   npm run gen:entitlement-keys
 */
import { generateKeyPair, exportPKCS8, exportSPKI } from 'jose';

const { publicKey, privateKey } = await generateKeyPair('EdDSA', { crv: 'Ed25519', extractable: true });
const priv = Buffer.from(await exportPKCS8(privateKey)).toString('base64');
const pub = Buffer.from(await exportSPKI(publicKey)).toString('base64');

console.log('# Entitlement token keypair (test/dev). Keep the private key secret.');
console.log(`ENTITLEMENT_ED25519_PRIVATE_KEY=${priv}`);
console.log(`ENTITLEMENT_ED25519_PUBLIC_KEY=${pub}`);
```

Add to `server/package.json` scripts (after `stripe:bootstrap`): `"gen:entitlement-keys": "tsx scripts/gen-entitlement-keys.ts",`

- [ ] **Step 8: Typecheck**

Run: `npm --prefix server run typecheck`
Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add server/package.json server/package-lock.json server/src/tokens/config.ts \
  server/src/tokens/signer.ts server/scripts/gen-entitlement-keys.ts server/test/tokens.test.ts
git commit -m "feat(server): ed25519 entitlement token signer + keygen"
```

---

### Task 2: Effective entitlement resolver

Collapses a user's `entitlements` rows into the single plan/status/updates_until that a token should carry. Deliverable: DB tests prove subscription-wins, one-time, and free resolution.

**Files:**
- Create: `server/src/billing/effective_entitlement.ts`
- Create: `server/test/effective-entitlement.test.ts`

**Interfaces:**
- Consumes: the DB (`entitlements` table); `testPool`/`resetDatabase`/`runMigrations`.
- Produces:
  - `type EffectiveEntitlement = { plan: 'subscription'|'onetime'|'free'; status: 'active'|'grace'|'canceled'|'none'; updatesUntil: string | null; export: boolean }`
  - `async function resolveEffectiveEntitlement(pool: pg.Pool, userId: string): Promise<EffectiveEntitlement>`

- [ ] **Step 1: Write the failing test `server/test/effective-entitlement.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { resolveEffectiveEntitlement } from '../src/billing/effective_entitlement.js';

async function seedUser(pool: pg.Pool, id: string) {
  await pool.query('INSERT INTO users (id, email) VALUES ($1, $2)', [id, `${id}@e.com`]);
}
async function addSub(pool: pg.Pool, userId: string, status: string) {
  await pool.query(
    `INSERT INTO entitlements (id, user_id, plan, status, stripe_subscription_id, current_period_end)
     VALUES ($1, $2, 'subscription', $3, $4, now() + interval '30 days')`,
    [`ent_${userId}_s`, userId, status, `sub_${userId}`]);
}
async function addOnetime(pool: pg.Pool, userId: string) {
  await pool.query(
    `INSERT INTO entitlements (id, user_id, plan, status, updates_until)
     VALUES ($1, $2, 'onetime', 'active', now() + interval '200 days')`,
    [`ent_${userId}_o`, userId]);
}

describe('resolveEffectiveEntitlement', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => { await pool.query('DELETE FROM entitlements'); await pool.query('DELETE FROM users'); });

  it('returns free when the user has no entitlements', async () => {
    await seedUser(pool, 'u_free');
    const e = await resolveEffectiveEntitlement(pool, 'u_free');
    expect(e).toEqual({ plan: 'free', status: 'none', updatesUntil: null, export: false });
  });

  it('active subscription wins and grants export', async () => {
    await seedUser(pool, 'u_sub'); await addSub(pool, 'u_sub', 'active');
    const e = await resolveEffectiveEntitlement(pool, 'u_sub');
    expect(e.plan).toBe('subscription'); expect(e.status).toBe('active'); expect(e.export).toBe(true);
  });

  it('grace subscription still grants export', async () => {
    await seedUser(pool, 'u_g'); await addSub(pool, 'u_g', 'grace');
    const e = await resolveEffectiveEntitlement(pool, 'u_g');
    expect(e.plan).toBe('subscription'); expect(e.status).toBe('grace'); expect(e.export).toBe(true);
  });

  it('one-time only returns onetime with an updates_until date', async () => {
    await seedUser(pool, 'u_ot'); await addOnetime(pool, 'u_ot');
    const e = await resolveEffectiveEntitlement(pool, 'u_ot');
    expect(e.plan).toBe('onetime'); expect(e.status).toBe('active'); expect(e.export).toBe(true);
    expect(typeof e.updatesUntil).toBe('string');
  });

  it('active subscription beats a one-time row', async () => {
    await seedUser(pool, 'u_both'); await addSub(pool, 'u_both', 'active'); await addOnetime(pool, 'u_both');
    const e = await resolveEffectiveEntitlement(pool, 'u_both');
    expect(e.plan).toBe('subscription');
  });

  it('canceled subscription falls back to a one-time row', async () => {
    await seedUser(pool, 'u_c'); await addSub(pool, 'u_c', 'canceled'); await addOnetime(pool, 'u_c');
    const e = await resolveEffectiveEntitlement(pool, 'u_c');
    expect(e.plan).toBe('onetime'); expect(e.export).toBe(true);
  });

  it('canceled subscription with no one-time is free', async () => {
    await seedUser(pool, 'u_co'); await addSub(pool, 'u_co', 'canceled');
    const e = await resolveEffectiveEntitlement(pool, 'u_co');
    expect(e.plan).toBe('free'); expect(e.export).toBe(false);
  });
});
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- effective-entitlement`

- [ ] **Step 3: Implement `server/src/billing/effective_entitlement.ts`**

```ts
import type pg from 'pg';

export type EffectiveEntitlement = {
  plan: 'subscription' | 'onetime' | 'free';
  status: 'active' | 'grace' | 'canceled' | 'none';
  updatesUntil: string | null;
  export: boolean;
};

/**
 * Collapse a user's entitlement rows into one effective entitlement:
 * an active/grace subscription wins; else any one-time grants export
 * (the version-ceiling check is client-side); else free.
 */
export async function resolveEffectiveEntitlement(
  pool: pg.Pool,
  userId: string,
): Promise<EffectiveEntitlement> {
  const { rows } = await pool.query<{
    plan: string; status: string; updates_until: Date | null;
  }>(
    `SELECT plan, status, updates_until FROM entitlements WHERE user_id = $1`,
    [userId],
  );

  const sub = rows.find(
    (r) => r.plan === 'subscription' && (r.status === 'active' || r.status === 'grace'),
  );
  if (sub) {
    return { plan: 'subscription', status: sub.status as 'active' | 'grace', updatesUntil: null, export: true };
  }

  const onetime = rows.find((r) => r.plan === 'onetime');
  if (onetime) {
    return {
      plan: 'onetime',
      status: 'active',
      updatesUntil: onetime.updates_until ? onetime.updates_until.toISOString() : null,
      export: true,
    };
  }

  return { plan: 'free', status: 'none', updatesUntil: null, export: false };
}
```

- [ ] **Step 4: Run it — expect PASS (7 tests)**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- effective-entitlement`

- [ ] **Step 5: Full suite + typecheck**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`

- [ ] **Step 6: Commit**

```bash
git add server/src/billing/effective_entitlement.ts server/test/effective-entitlement.test.ts
git commit -m "feat(server): resolve effective entitlement from rows"
```

---

### Task 3: Sessions schema + secret-token helper + session store

Migration `0004` (sessions + magic_links), a shared hashed-random-token helper, and the DB session store. Deliverable: DB tests prove a session round-trips and expires.

**Files:**
- Create: `server/migrations/0004_auth.sql`
- Create: `server/src/auth/secret_token.ts`
- Create: `server/src/auth/sessions.ts`
- Create: `server/test/sessions.test.ts`

**Interfaces:**
- Consumes: `newId` (ids.ts); the DB.
- Produces:
  - `function newSecretToken(): { token: string; hash: string }` (token = 32 random bytes base64url; hash = sha256 hex)
  - `function hashToken(token: string): string`
  - `async function createSession(pool, userId, ttlHours?): Promise<{ token: string; expiresAt: Date }>` (default 720h = 30d)
  - `async function resolveSession(pool, token): Promise<{ userId: string } | null>`
  - `async function deleteSession(pool, token): Promise<void>`

- [ ] **Step 1: Write `server/migrations/0004_auth.sql`**

```sql
CREATE TABLE sessions (
  id          text PRIMARY KEY,
  user_id     text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash  text UNIQUE NOT NULL,
  expires_at  timestamptz NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sessions_user_id_idx ON sessions(user_id);

CREATE TABLE magic_links (
  id          text PRIMARY KEY,
  user_id     text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash  text UNIQUE NOT NULL,
  expires_at  timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
```

- [ ] **Step 2: Write the failing test `server/test/sessions.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { newSecretToken, hashToken } from '../src/auth/secret_token.js';
import { createSession, resolveSession, deleteSession } from '../src/auth/sessions.js';

describe('secret_token', () => {
  it('produces a token and its sha256 hash, unique per call', () => {
    const a = newSecretToken();
    const b = newSecretToken();
    expect(a.token).not.toBe(b.token);
    expect(a.hash).toBe(hashToken(a.token));
    expect(a.hash).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe('sessions', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM sessions'); await pool.query('DELETE FROM users');
    await pool.query("INSERT INTO users (id, email) VALUES ('u1', 'u1@e.com')");
  });

  it('creates a session that resolves to the user', async () => {
    const { token } = await createSession(pool, 'u1');
    expect(await resolveSession(pool, token)).toEqual({ userId: 'u1' });
  });

  it('returns null for an unknown token', async () => {
    expect(await resolveSession(pool, 'nope')).toBeNull();
  });

  it('returns null for an expired session', async () => {
    const { token } = await createSession(pool, 'u1', 0); // expires now
    // force-expire in case of clock granularity
    await pool.query("UPDATE sessions SET expires_at = now() - interval '1 minute'");
    expect(await resolveSession(pool, token)).toBeNull();
  });

  it('delete removes the session', async () => {
    const { token } = await createSession(pool, 'u1');
    await deleteSession(pool, token);
    expect(await resolveSession(pool, token)).toBeNull();
  });
});
```

- [ ] **Step 3: Run it — expect FAIL**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- sessions`

- [ ] **Step 4: Implement `server/src/auth/secret_token.ts`**

```ts
import { randomBytes, createHash } from 'node:crypto';

export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

/** A high-entropy opaque token plus its sha256 hash (only the hash is stored). */
export function newSecretToken(): { token: string; hash: string } {
  const token = randomBytes(32).toString('base64url');
  return { token, hash: hashToken(token) };
}
```

- [ ] **Step 5: Implement `server/src/auth/sessions.ts`**

```ts
import type pg from 'pg';
import { newId } from '../ids.js';
import { newSecretToken, hashToken } from './secret_token.js';

export async function createSession(
  pool: pg.Pool,
  userId: string,
  ttlHours = 720,
): Promise<{ token: string; expiresAt: Date }> {
  const { token, hash } = newSecretToken();
  const expiresAt = new Date(Date.now() + ttlHours * 3600_000);
  await pool.query(
    'INSERT INTO sessions (id, user_id, token_hash, expires_at) VALUES ($1, $2, $3, $4)',
    [newId('ses'), userId, hash, expiresAt],
  );
  return { token, expiresAt };
}

export async function resolveSession(
  pool: pg.Pool,
  token: string,
): Promise<{ userId: string } | null> {
  const { rows } = await pool.query<{ user_id: string }>(
    'SELECT user_id FROM sessions WHERE token_hash = $1 AND expires_at > now()',
    [hashToken(token)],
  );
  return rows[0] ? { userId: rows[0].user_id } : null;
}

export async function deleteSession(pool: pg.Pool, token: string): Promise<void> {
  await pool.query('DELETE FROM sessions WHERE token_hash = $1', [hashToken(token)]);
}
```

Note: `createSession(pool, userId, 0)` yields `expires_at = now` which `> now()` excludes almost immediately; the test also force-updates to be deterministic.

- [ ] **Step 6: Run it — expect PASS (5 tests)**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- sessions`

- [ ] **Step 7: Full suite + typecheck, then commit**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`

```bash
git add server/migrations/0004_auth.sql server/src/auth/secret_token.ts \
  server/src/auth/sessions.ts server/test/sessions.test.ts
git commit -m "feat(server): sessions + magic_links schema and session store"
```

---

### Task 4: Cookie + requireSession + session-from-checkout + licensing guard + test helper

Adds `@fastify/cookie`, the session cookie helpers, the `requireSession` preHandler, the `session-from-checkout` + `logout` routes, extends `buildApp` with the optional `tokenSigner` dep and a licensing guard, and a shared test helper for the route tests. Deliverable: tests prove checkout-session login sets a cookie and that `requireSession` gates a protected route.

**Files:**
- Modify: `server/package.json` (add `@fastify/cookie`)
- Create: `server/src/auth/cookie.ts`
- Create: `server/src/auth/require_session.ts`
- Create: `server/src/routes/auth.ts`
- Modify: `server/src/app.ts`
- Create: `server/test/helpers/licensing.ts`
- Create: `server/test/auth-routes.test.ts`

**Interfaces:**
- Consumes: `createSession`/`resolveSession`/`deleteSession` (Task 3); `TokenSigner` (Task 1); `app.stripe` (Phase 2); `BillingConfig` (Phase 2).
- Produces:
  - `const SESSION_COOKIE = 'slipreel_session'`; `setSessionCookie(reply, token, expiresAt)`; `clearSessionCookie(reply)`
  - `function requireSession(app): preHandlerHookHandler` — sets `req.userId`, else 401
  - `async function authRoutes(app)` — `POST /v1/auth/session-from-checkout`, `POST /v1/auth/logout`
  - Extended `AppDeps` with `tokenSigner?: TokenSigner`; `app.tokenSigner` decoration
  - `test/helpers/licensing.ts`: `async function makeTestSigner(): Promise<TokenSigner>` and `async function makeLicensingApp(pool, opts?): Promise<{ app; signer; publicKeyPem; stripe; stripeState }>`

- [ ] **Step 1: Add `@fastify/cookie` to `server/package.json`** and install.

Add dep `"@fastify/cookie": "^10.0.1"`, then `npm --prefix server install`.

- [ ] **Step 2: Implement `server/src/auth/cookie.ts`**

```ts
import type { FastifyReply } from 'fastify';

export const SESSION_COOKIE = 'slipreel_session';

export function setSessionCookie(reply: FastifyReply, token: string, expiresAt: Date): void {
  reply.setCookie(SESSION_COOKIE, token, {
    httpOnly: true,
    secure: true,
    sameSite: 'lax',
    path: '/',
    expires: expiresAt,
  });
}

export function clearSessionCookie(reply: FastifyReply): void {
  reply.clearCookie(SESSION_COOKIE, { path: '/' });
}
```

- [ ] **Step 3: Implement `server/src/auth/require_session.ts`**

```ts
import type { FastifyInstance, preHandlerHookHandler } from 'fastify';
import { resolveSession } from './sessions.js';
import { SESSION_COOKIE } from './cookie.js';

declare module 'fastify' {
  interface FastifyRequest {
    userId?: string;
  }
}

/** preHandler that requires a valid session cookie; sets req.userId or 401s. */
export function requireSession(app: FastifyInstance): preHandlerHookHandler {
  return async (req, reply) => {
    const token = req.cookies?.[SESSION_COOKIE];
    if (!token) return reply.code(401).send({ error: 'not authenticated' });
    const session = await resolveSession(app.pool, token);
    if (!session) return reply.code(401).send({ error: 'not authenticated' });
    req.userId = session.userId;
  };
}
```

- [ ] **Step 4: Implement `server/src/routes/auth.ts`**

```ts
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { createSession, deleteSession } from '../auth/sessions.js';
import { setSessionCookie, clearSessionCookie, SESSION_COOKIE } from '../auth/cookie.js';
import { requireSession } from '../auth/require_session.js';

const fromCheckout = z.object({ checkout_session_id: z.string().min(1) });

export async function authRoutes(app: FastifyInstance): Promise<void> {
  // Reuse a completed Stripe Checkout session to log the buyer in (no password).
  app.post('/v1/auth/session-from-checkout', async (req, reply) => {
    const parsed = fromCheckout.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const cs = await app.stripe.checkout.sessions.retrieve(parsed.data.checkout_session_id);
    if (cs.status !== 'complete') return reply.code(400).send({ error: 'checkout not complete' });

    const customer = typeof cs.customer === 'string' ? cs.customer : cs.customer?.id;
    if (!customer) return reply.code(400).send({ error: 'no customer on session' });

    const { rows } = await app.pool.query<{ id: string; email: string }>(
      'SELECT id, email FROM users WHERE stripe_customer_id = $1',
      [customer],
    );
    const user = rows[0];
    if (!user) return reply.code(404).send({ error: 'no user for customer' });

    const { token, expiresAt } = await createSession(app.pool, user.id);
    setSessionCookie(reply, token, expiresAt);
    return reply.send({ user: { id: user.id, email: user.email } });
  });

  app.post('/v1/auth/logout', { preHandler: requireSession(app) }, async (req, reply) => {
    const token = req.cookies?.[SESSION_COOKIE];
    if (token) await deleteSession(app.pool, token);
    clearSessionCookie(reply);
    return reply.send({ ok: true });
  });
}
```

- [ ] **Step 5: Modify `server/src/app.ts`** — add the `tokenSigner` dep, decoration, and the licensing guard (registers cookie + auth routes).

Add imports at top:

```ts
import cookie from '@fastify/cookie';
import type { TokenSigner } from './tokens/signer.js';
import { authRoutes } from './routes/auth.js';
```

Extend the module augmentation to add `tokenSigner: TokenSigner;` alongside `pool`/`stripe`/`billing`. Extend `AppDeps` with `tokenSigner?: TokenSigner;`. Then, AFTER the existing `if (deps.stripe && deps.billing) { … }` block, add:

```ts
  // Licensing (auth + tokens) is optional: registered only when a token signer
  // is provided (alongside stripe+billing, which session-from-checkout needs).
  if (deps.tokenSigner && deps.stripe && deps.billing) {
    app.decorate('tokenSigner', deps.tokenSigner);
    app.register(cookie);
    app.register(authRoutes);
  }
```

- [ ] **Step 6: Implement the shared test helper `server/test/helpers/licensing.ts`**

```ts
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import type Stripe from 'stripe';
import { generateKeyPair, exportPKCS8, exportSPKI } from 'jose';
import { loadTokenConfig } from '../../src/tokens/config.js';
import { createTokenSigner, type TokenSigner } from '../../src/tokens/signer.js';
import type { BillingConfig } from '../../src/billing/config.js';
import { buildApp } from '../../src/app.js';

export async function makeTestSigner(): Promise<TokenSigner> {
  const { publicKey, privateKey } = await generateKeyPair('EdDSA', { crv: 'Ed25519', extractable: true });
  return createTokenSigner(loadTokenConfig({
    ENTITLEMENT_ED25519_PRIVATE_KEY: Buffer.from(await exportPKCS8(privateKey)).toString('base64'),
    ENTITLEMENT_ED25519_PUBLIC_KEY: Buffer.from(await exportSPKI(publicKey)).toString('base64'),
    ENTITLEMENT_ISSUER: 'https://api.slipreel.test',
    ENTITLEMENT_TOKEN_TTL_DAYS: '14',
  }));
}

const billing: BillingConfig = {
  secretKey: 'sk_test_dummy', webhookSecret: 'whsec_x',
  prices: { monthly: 'price_m', yearly: 'price_y', onetime: 'price_o' },
  successUrl: 'https://slipreel.app/success', cancelUrl: 'https://slipreel.app/pricing',
  portalReturnUrl: 'https://slipreel.app/account',
};

/**
 * Build a licensing-enabled app with a fresh signer and a fake Stripe whose
 * checkout.sessions.retrieve is controllable. `stripeState.session` is what
 * retrieve() returns; tests set it per case.
 */
export async function makeLicensingApp(
  pool: pg.Pool,
  opts: { session?: unknown } = {},
): Promise<{ app: FastifyInstance; signer: TokenSigner; stripeState: { session: unknown } }> {
  const signer = await makeTestSigner();
  const stripeState: { session: unknown } = { session: opts.session ?? null };
  const stripe = {
    checkout: { sessions: { retrieve: async (_id: string) => stripeState.session } },
  } as unknown as Stripe;
  const app = buildApp({ pool, stripe, billing, tokenSigner: signer, logger: false });
  await app.ready();
  return { app, signer, stripeState };
}
```

- [ ] **Step 7: Write the failing test `server/test/auth-routes.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';

describe('auth routes', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM sessions'); await pool.query('DELETE FROM users');
    await pool.query("INSERT INTO users (id, email, stripe_customer_id) VALUES ('u_c','c@e.com','cus_c')");
  });

  it('session-from-checkout on a complete session sets a cookie and returns the user', async () => {
    const { app } = await makeLicensingApp(pool, {
      session: { status: 'complete', customer: 'cus_c' },
    });
    const res = await app.inject({ method: 'POST', url: '/v1/auth/session-from-checkout',
      payload: { checkout_session_id: 'cs_1' } });
    expect(res.statusCode).toBe(200);
    expect(res.json().user).toEqual({ id: 'u_c', email: 'c@e.com' });
    expect(String(res.headers['set-cookie'])).toContain('slipreel_session=');
    await app.close();
  });

  it('rejects an incomplete checkout session with 400', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'open', customer: 'cus_c' } });
    const res = await app.inject({ method: 'POST', url: '/v1/auth/session-from-checkout',
      payload: { checkout_session_id: 'cs_2' } });
    expect(res.statusCode).toBe(400);
    await app.close();
  });

  it('404s when the session customer has no user', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_unknown' } });
    const res = await app.inject({ method: 'POST', url: '/v1/auth/session-from-checkout',
      payload: { checkout_session_id: 'cs_3' } });
    expect(res.statusCode).toBe(404);
    await app.close();
  });

  it('logout requires a session (401 without cookie) and clears it with one', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_c' } });
    // no cookie -> 401
    const no = await app.inject({ method: 'POST', url: '/v1/auth/logout' });
    expect(no.statusCode).toBe(401);
    // login, capture cookie, then logout -> 200
    const login = await app.inject({ method: 'POST', url: '/v1/auth/session-from-checkout',
      payload: { checkout_session_id: 'cs_1' } });
    const cookie = String(login.headers['set-cookie']).split(';')[0];
    const out = await app.inject({ method: 'POST', url: '/v1/auth/logout', headers: { cookie } });
    expect(out.statusCode).toBe(200);
    await app.close();
  });
});
```

- [ ] **Step 8: Run it — expect FAIL, then implement is already done in Steps 2-6; run PASS**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- auth-routes`
(If it failed only because files didn't exist, they now do; expect PASS with 4 tests. Confirm the Phase-1/2 tests still pass: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test` and `npm --prefix server run typecheck`.)

- [ ] **Step 9: Commit**

```bash
git add server/package.json server/package-lock.json server/src/auth/cookie.ts \
  server/src/auth/require_session.ts server/src/routes/auth.ts server/src/app.ts \
  server/test/helpers/licensing.ts server/test/auth-routes.test.ts
git commit -m "feat(server): passwordless session-from-checkout + session cookie"
```

---

### Task 5: Magic-link request + verify

A single-use magic link for returning users on a new device; email delivery is stubbed (token returned only when `NODE_ENV !== 'production'`). Deliverable: tests prove request→verify establishes a session and a link is single-use.

**Files:**
- Create: `server/src/auth/magic_link.ts`
- Create: `server/src/routes/magic-link.ts`
- Modify: `server/src/app.ts` (register `magicLinkRoutes` in the licensing guard)
- Create: `server/test/magic-link.test.ts`

**Interfaces:**
- Consumes: `createMagicLink`/`consumeMagicLink`; `createSession`; the cookie helpers.
- Produces:
  - `async function createMagicLink(pool, userId, ttlMinutes?): Promise<{ token: string }>` (default 15 min)
  - `async function consumeMagicLink(pool, token): Promise<{ userId: string } | null>` (single-use)
  - `async function magicLinkRoutes(app)` — `POST /v1/auth/magic-link`, `POST /v1/auth/magic-link/verify`

- [ ] **Step 1: Implement `server/src/auth/magic_link.ts`**

```ts
import type pg from 'pg';
import { newId } from '../ids.js';
import { newSecretToken, hashToken } from './secret_token.js';

export async function createMagicLink(
  pool: pg.Pool,
  userId: string,
  ttlMinutes = 15,
): Promise<{ token: string }> {
  const { token, hash } = newSecretToken();
  const expiresAt = new Date(Date.now() + ttlMinutes * 60_000);
  await pool.query(
    'INSERT INTO magic_links (id, user_id, token_hash, expires_at) VALUES ($1, $2, $3, $4)',
    [newId('mlk'), userId, hash, expiresAt],
  );
  return { token };
}

/** Consume a link atomically: only an unexpired, unconsumed link succeeds. */
export async function consumeMagicLink(
  pool: pg.Pool,
  token: string,
): Promise<{ userId: string } | null> {
  const { rows } = await pool.query<{ user_id: string }>(
    `UPDATE magic_links SET consumed_at = now()
     WHERE token_hash = $1 AND consumed_at IS NULL AND expires_at > now()
     RETURNING user_id`,
    [hashToken(token)],
  );
  return rows[0] ? { userId: rows[0].user_id } : null;
}
```

- [ ] **Step 2: Implement `server/src/routes/magic-link.ts`**

```ts
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { createMagicLink, consumeMagicLink } from '../auth/magic_link.js';
import { createSession } from '../auth/sessions.js';
import { setSessionCookie } from '../auth/cookie.js';

const requestBody = z.object({ email: z.string().email() });
const verifyBody = z.object({ token: z.string().min(1) });

export async function magicLinkRoutes(app: FastifyInstance): Promise<void> {
  // Request a sign-in link. Always 200 (don't leak which emails exist).
  // Email delivery is stubbed: the link is logged, and the token is returned
  // ONLY in non-production so the flow is testable until a provider is wired.
  app.post('/v1/auth/magic-link', async (req, reply) => {
    const parsed = requestBody.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const { rows } = await app.pool.query<{ id: string }>(
      'SELECT id FROM users WHERE email = $1',
      [parsed.data.email],
    );
    const user = rows[0];
    if (user) {
      const { token } = await createMagicLink(app.pool, user.id);
      app.log.info({ email: parsed.data.email }, 'magic link issued (email delivery stubbed)');
      if (process.env.NODE_ENV !== 'production') {
        return reply.send({ sent: true, debug_token: token });
      }
    }
    return reply.send({ sent: true });
  });

  // Verify a link -> establish a session cookie.
  app.post('/v1/auth/magic-link/verify', async (req, reply) => {
    const parsed = verifyBody.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const consumed = await consumeMagicLink(app.pool, parsed.data.token);
    if (!consumed) return reply.code(401).send({ error: 'invalid or used link' });

    const { rows } = await app.pool.query<{ id: string; email: string }>(
      'SELECT id, email FROM users WHERE id = $1',
      [consumed.userId],
    );
    const { token, expiresAt } = await createSession(app.pool, consumed.userId);
    setSessionCookie(reply, token, expiresAt);
    return reply.send({ user: rows[0] ? { id: rows[0].id, email: rows[0].email } : { id: consumed.userId } });
  });
}
```

- [ ] **Step 3: Register in `server/src/app.ts`** — add the import and one registration line in the licensing guard:

```ts
import { magicLinkRoutes } from './routes/magic-link.js';
```
```ts
    app.register(authRoutes);
    app.register(magicLinkRoutes);
```

- [ ] **Step 4: Write the failing test `server/test/magic-link.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';

describe('magic link', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM magic_links'); await pool.query('DELETE FROM sessions');
    await pool.query('DELETE FROM users');
    await pool.query("INSERT INTO users (id, email) VALUES ('u_m','m@e.com')");
  });

  it('issues a debug token for a known email and verifies it into a session', async () => {
    const { app } = await makeLicensingApp(pool);
    const req = await app.inject({ method: 'POST', url: '/v1/auth/magic-link', payload: { email: 'm@e.com' } });
    expect(req.statusCode).toBe(200);
    const token = req.json().debug_token as string;
    expect(token).toBeTruthy();

    const ver = await app.inject({ method: 'POST', url: '/v1/auth/magic-link/verify', payload: { token } });
    expect(ver.statusCode).toBe(200);
    expect(ver.json().user.id).toBe('u_m');
    expect(String(ver.headers['set-cookie'])).toContain('slipreel_session=');
    await app.close();
  });

  it('does not leak existence for an unknown email (200, no token)', async () => {
    const { app } = await makeLicensingApp(pool);
    const req = await app.inject({ method: 'POST', url: '/v1/auth/magic-link', payload: { email: 'nobody@e.com' } });
    expect(req.statusCode).toBe(200);
    expect(req.json().debug_token).toBeUndefined();
    await app.close();
  });

  it('a link is single-use (second verify 401s)', async () => {
    const { app } = await makeLicensingApp(pool);
    const token = (await app.inject({ method: 'POST', url: '/v1/auth/magic-link', payload: { email: 'm@e.com' } })).json().debug_token;
    await app.inject({ method: 'POST', url: '/v1/auth/magic-link/verify', payload: { token } });
    const again = await app.inject({ method: 'POST', url: '/v1/auth/magic-link/verify', payload: { token } });
    expect(again.statusCode).toBe(401);
    await app.close();
  });

  it('rejects a bogus token', async () => {
    const { app } = await makeLicensingApp(pool);
    const res = await app.inject({ method: 'POST', url: '/v1/auth/magic-link/verify', payload: { token: 'bogus' } });
    expect(res.statusCode).toBe(401);
    await app.close();
  });
});
```

- [ ] **Step 5: Run — expect PASS (4 tests)**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- magic-link`
(vitest sets `NODE_ENV=test`, so `debug_token` is returned.)

- [ ] **Step 6: Full suite + typecheck, then commit**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`

```bash
git add server/src/auth/magic_link.ts server/src/routes/magic-link.ts server/src/app.ts server/test/magic-link.test.ts
git commit -m "feat(server): single-use magic-link auth (email stubbed)"
```

---

### Task 6: Device registration + token minting (`/v1/token`, `/v1/token/refresh`)

The heart of the phase: register the calling device under the 2-seat limit and mint the entitlement token; refresh re-mints from a device token without a cookie. Deliverable: tests prove minting + claims, seat enforcement (409 on the 3rd device), and refresh.

**Files:**
- Create: `server/src/auth/devices.ts`
- Create: `server/src/routes/token.ts`
- Modify: `server/src/app.ts` (register `tokenRoutes` in the licensing guard)
- Create: `server/test/token-routes.test.ts`

**Interfaces:**
- Consumes: `requireSession`; `resolveEffectiveEntitlement` (Task 2); `app.tokenSigner`; `newId`, `newSecretToken`/`hashToken`.
- Produces:
  - `const SEAT_LIMIT = 2`
  - `type DeviceInfo = { id: string; name: string | null; lastSeenAt: string | null }`
  - `async function registerDevice(pool, userId, fingerprint, name, seatLimit): Promise<{ ok: true; deviceId: string; refreshToken: string } | { ok: false; reason: 'seat_limit'; devices: DeviceInfo[] }>`
  - `async function refreshDevice(pool, deviceId, refreshToken): Promise<{ userId: string } | null>`
  - `async function tokenRoutes(app)` — `POST /v1/token`, `POST /v1/token/refresh`

- [ ] **Step 1: Implement `server/src/auth/devices.ts`**

```ts
import type pg from 'pg';
import { newId } from '../ids.js';
import { newSecretToken, hashToken } from './secret_token.js';

export const SEAT_LIMIT = 2;

export type DeviceInfo = { id: string; name: string | null; lastSeenAt: string | null };

/**
 * Register (or re-activate) the device identified by `fingerprint` for a user.
 * A known fingerprint rotates its refresh token (no new seat). A new
 * fingerprint consumes a seat; over `seatLimit` returns a seat_limit result
 * with the current device list so the client can prompt to deactivate one.
 */
export async function registerDevice(
  pool: pg.Pool,
  userId: string,
  fingerprint: string,
  name: string | null,
  seatLimit: number,
): Promise<
  | { ok: true; deviceId: string; refreshToken: string }
  | { ok: false; reason: 'seat_limit'; devices: DeviceInfo[] }
> {
  const { token, hash } = newSecretToken();

  const existing = await pool.query<{ id: string }>(
    'SELECT id FROM devices WHERE user_id = $1 AND fingerprint = $2',
    [userId, fingerprint],
  );
  if (existing.rows[0]) {
    const id = existing.rows[0].id;
    await pool.query(
      'UPDATE devices SET refresh_token_hash = $1, name = COALESCE($2, name), last_seen_at = now() WHERE id = $3',
      [hash, name, id],
    );
    return { ok: true, deviceId: id, refreshToken: token };
  }

  const count = await pool.query<{ n: string }>(
    'SELECT count(*)::int AS n FROM devices WHERE user_id = $1',
    [userId],
  );
  if (Number(count.rows[0]!.n) >= seatLimit) {
    const list = await pool.query<{ id: string; name: string | null; last_seen_at: Date | null }>(
      'SELECT id, name, last_seen_at FROM devices WHERE user_id = $1 ORDER BY created_at',
      [userId],
    );
    return {
      ok: false,
      reason: 'seat_limit',
      devices: list.rows.map((r) => ({ id: r.id, name: r.name, lastSeenAt: r.last_seen_at?.toISOString() ?? null })),
    };
  }

  const id = newId('dev');
  await pool.query(
    'INSERT INTO devices (id, user_id, fingerprint, name, refresh_token_hash, last_seen_at) VALUES ($1,$2,$3,$4,$5,now())',
    [id, userId, fingerprint, name, hash],
  );
  return { ok: true, deviceId: id, refreshToken: token };
}

/** Validate a device refresh token; on success bump last_seen and return the owner. */
export async function refreshDevice(
  pool: pg.Pool,
  deviceId: string,
  refreshToken: string,
): Promise<{ userId: string } | null> {
  const { rows } = await pool.query<{ user_id: string }>(
    'UPDATE devices SET last_seen_at = now() WHERE id = $1 AND refresh_token_hash = $2 RETURNING user_id',
    [deviceId, hashToken(refreshToken)],
  );
  return rows[0] ? { userId: rows[0].user_id } : null;
}
```

- [ ] **Step 2: Implement `server/src/routes/token.ts`**

```ts
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireSession } from '../auth/require_session.js';
import { registerDevice, refreshDevice, SEAT_LIMIT } from '../auth/devices.js';
import { resolveEffectiveEntitlement } from '../billing/effective_entitlement.js';

const tokenBody = z.object({ fingerprint: z.string().min(1), device_name: z.string().optional() });
const refreshReq = z.object({ refresh_token: z.string().min(1), device_id: z.string().min(1) });

async function mintFor(app: FastifyInstance, userId: string, deviceId: string): Promise<string> {
  const eff = await resolveEffectiveEntitlement(app.pool, userId);
  return app.tokenSigner.mint({
    sub: userId,
    plan: eff.plan,
    export: eff.export,
    status: eff.status,
    updates_until: eff.updatesUntil,
    device_id: deviceId,
    seat_limit: SEAT_LIMIT,
  });
}

export async function tokenRoutes(app: FastifyInstance): Promise<void> {
  app.post('/v1/token', { preHandler: requireSession(app) }, async (req, reply) => {
    const parsed = tokenBody.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const reg = await registerDevice(
      app.pool, req.userId!, parsed.data.fingerprint, parsed.data.device_name ?? null, SEAT_LIMIT,
    );
    if (!reg.ok) return reply.code(409).send({ error: 'seat_limit', devices: reg.devices });

    const token = await mintFor(app, req.userId!, reg.deviceId);
    return reply.send({ token, refresh_token: reg.refreshToken, device_id: reg.deviceId });
  });

  app.post('/v1/token/refresh', async (req, reply) => {
    const parsed = refreshReq.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const dev = await refreshDevice(app.pool, parsed.data.device_id, parsed.data.refresh_token);
    if (!dev) return reply.code(401).send({ error: 'invalid refresh token' });

    const token = await mintFor(app, dev.userId, parsed.data.device_id);
    return reply.send({ token });
  });
}
```

- [ ] **Step 3: Register in `server/src/app.ts`** — import and one registration line in the licensing guard:

```ts
import { tokenRoutes } from './routes/token.js';
```
```ts
    app.register(magicLinkRoutes);
    app.register(tokenRoutes);
```

- [ ] **Step 4: Write the failing test `server/test/token-routes.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';

// Log a user in via session-from-checkout and return the session cookie.
async function login(app: any, customer: string): Promise<string> {
  const res = await app.inject({ method: 'POST', url: '/v1/auth/session-from-checkout',
    payload: { checkout_session_id: 'cs' } });
  return String(res.headers['set-cookie']).split(';')[0];
}

describe('token routes', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM devices'); await pool.query('DELETE FROM sessions');
    await pool.query('DELETE FROM entitlements'); await pool.query('DELETE FROM users');
    await pool.query("INSERT INTO users (id, email, stripe_customer_id) VALUES ('u1','u1@e.com','cus_1')");
    await pool.query(
      `INSERT INTO entitlements (id, user_id, plan, status, stripe_subscription_id, current_period_end)
       VALUES ('e1','u1','subscription','active','sub_1', now() + interval '30 days')`);
  });

  it('mints a verifiable token whose claims reflect the subscription', async () => {
    const { app, signer } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const cookie = await login(app, 'cus_1');
    const res = await app.inject({ method: 'POST', url: '/v1/token', headers: { cookie },
      payload: { fingerprint: 'fp-a', device_name: 'MacBook' } });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.token).toBeTruthy();
    expect(body.refresh_token).toBeTruthy();
    expect(body.device_id).toMatch(/^dev_/);
    const claims = await signer.verify(body.token);
    expect(claims.sub).toBe('u1');
    expect(claims.plan).toBe('subscription');
    expect(claims.export).toBe(true);
    expect(claims.device_id).toBe(body.device_id);
    expect(claims.seat_limit).toBe(2);
    await app.close();
  });

  it('requires a session (401 without cookie)', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const res = await app.inject({ method: 'POST', url: '/v1/token', payload: { fingerprint: 'fp-a' } });
    expect(res.statusCode).toBe(401);
    await app.close();
  });

  it('enforces the 2-device seat limit (3rd fingerprint -> 409 with device list)', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const cookie = await login(app, 'cus_1');
    for (const fp of ['fp-1', 'fp-2']) {
      const ok = await app.inject({ method: 'POST', url: '/v1/token', headers: { cookie }, payload: { fingerprint: fp } });
      expect(ok.statusCode).toBe(200);
    }
    const third = await app.inject({ method: 'POST', url: '/v1/token', headers: { cookie }, payload: { fingerprint: 'fp-3' } });
    expect(third.statusCode).toBe(409);
    expect(third.json().error).toBe('seat_limit');
    expect(third.json().devices).toHaveLength(2);
    await app.close();
  });

  it('re-activating a known fingerprint does not consume a new seat', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const cookie = await login(app, 'cus_1');
    await app.inject({ method: 'POST', url: '/v1/token', headers: { cookie }, payload: { fingerprint: 'fp-1' } });
    await app.inject({ method: 'POST', url: '/v1/token', headers: { cookie }, payload: { fingerprint: 'fp-1' } });
    const { rows } = await pool.query(`SELECT count(*)::int AS n FROM devices WHERE user_id = 'u1'`);
    expect(rows[0].n).toBe(1);
    await app.close();
  });

  it('refresh returns a new token for a valid device token; 401 for a bad one', async () => {
    const { app, signer } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const cookie = await login(app, 'cus_1');
    const mint = (await app.inject({ method: 'POST', url: '/v1/token', headers: { cookie }, payload: { fingerprint: 'fp-1' } })).json();
    const good = await app.inject({ method: 'POST', url: '/v1/token/refresh',
      payload: { refresh_token: mint.refresh_token, device_id: mint.device_id } });
    expect(good.statusCode).toBe(200);
    const claims = await signer.verify(good.json().token);
    expect(claims.device_id).toBe(mint.device_id);
    const bad = await app.inject({ method: 'POST', url: '/v1/token/refresh',
      payload: { refresh_token: 'wrong', device_id: mint.device_id } });
    expect(bad.statusCode).toBe(401);
    await app.close();
  });
});
```

- [ ] **Step 5: Run — expect PASS (5 tests)**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- token-routes`

- [ ] **Step 6: Full suite + typecheck, then commit**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`

```bash
git add server/src/auth/devices.ts server/src/routes/token.ts server/src/app.ts server/test/token-routes.test.ts
git commit -m "feat(server): device registration, seat limit, and token minting"
```

---

### Task 7: Device management (`GET /v1/devices`, `DELETE /v1/devices/:id`)

Let a user list and deactivate their devices (freeing a seat). Deliverable: tests prove list/delete and ownership + auth enforcement.

**Files:**
- Create: `server/src/routes/devices.ts`
- Modify: `server/src/app.ts` (register `deviceRoutes` in the licensing guard)
- Create: `server/test/devices-routes.test.ts`

**Interfaces:**
- Consumes: `requireSession`.
- Produces: `async function deviceRoutes(app)` — `GET /v1/devices`, `DELETE /v1/devices/:id`.

- [ ] **Step 1: Implement `server/src/routes/devices.ts`**

```ts
import type { FastifyInstance } from 'fastify';
import { requireSession } from '../auth/require_session.js';

export async function deviceRoutes(app: FastifyInstance): Promise<void> {
  app.get('/v1/devices', { preHandler: requireSession(app) }, async (req, reply) => {
    const { rows } = await app.pool.query<{ id: string; name: string | null; last_seen_at: Date | null; created_at: Date }>(
      'SELECT id, name, last_seen_at, created_at FROM devices WHERE user_id = $1 ORDER BY created_at',
      [req.userId!],
    );
    return reply.send({
      devices: rows.map((r) => ({
        id: r.id, name: r.name,
        last_seen_at: r.last_seen_at?.toISOString() ?? null,
        created_at: r.created_at.toISOString(),
      })),
    });
  });

  app.delete('/v1/devices/:id', { preHandler: requireSession(app) }, async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const { rowCount } = await app.pool.query(
      'DELETE FROM devices WHERE id = $1 AND user_id = $2',
      [id, req.userId!],
    );
    if (rowCount === 0) return reply.code(404).send({ error: 'not found' });
    return reply.send({ ok: true });
  });
}
```

- [ ] **Step 2: Register in `server/src/app.ts`** — import + one registration line in the licensing guard:

```ts
import { deviceRoutes } from './routes/devices.js';
```
```ts
    app.register(tokenRoutes);
    app.register(deviceRoutes);
```

- [ ] **Step 3: Write the failing test `server/test/devices-routes.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';

async function login(app: any): Promise<string> {
  const res = await app.inject({ method: 'POST', url: '/v1/auth/session-from-checkout',
    payload: { checkout_session_id: 'cs' } });
  return String(res.headers['set-cookie']).split(';')[0];
}

describe('device routes', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM devices'); await pool.query('DELETE FROM sessions'); await pool.query('DELETE FROM users');
    await pool.query("INSERT INTO users (id, email, stripe_customer_id) VALUES ('u1','u1@e.com','cus_1')");
    await pool.query("INSERT INTO users (id, email, stripe_customer_id) VALUES ('u2','u2@e.com','cus_2')");
  });

  it('lists the user devices and deletes one (freeing a seat)', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const cookie = await login(app);
    await app.inject({ method: 'POST', url: '/v1/token', headers: { cookie }, payload: { fingerprint: 'fp-1', device_name: 'A' } });
    await app.inject({ method: 'POST', url: '/v1/token', headers: { cookie }, payload: { fingerprint: 'fp-2', device_name: 'B' } });

    const list = await app.inject({ method: 'GET', url: '/v1/devices', headers: { cookie } });
    expect(list.statusCode).toBe(200);
    const devices = list.json().devices as Array<{ id: string }>;
    expect(devices).toHaveLength(2);

    const del = await app.inject({ method: 'DELETE', url: `/v1/devices/${devices[0].id}`, headers: { cookie } });
    expect(del.statusCode).toBe(200);
    const after = await app.inject({ method: 'GET', url: '/v1/devices', headers: { cookie } });
    expect(after.json().devices).toHaveLength(1);
    await app.close();
  });

  it('requires auth (401)', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const res = await app.inject({ method: 'GET', url: '/v1/devices' });
    expect(res.statusCode).toBe(401);
    await app.close();
  });

  it("404s when deleting another user's device", async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    // seed a device owned by u2 directly
    await pool.query("INSERT INTO devices (id, user_id, fingerprint, refresh_token_hash) VALUES ('dev_u2','u2','fpx','h')");
    const cookie = await login(app);
    const del = await app.inject({ method: 'DELETE', url: '/v1/devices/dev_u2', headers: { cookie } });
    expect(del.statusCode).toBe(404);
    await app.close();
  });
});
```

- [ ] **Step 4: Run — expect PASS (3 tests)**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- devices-routes`

- [ ] **Step 5: Full suite + typecheck, then commit**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`

```bash
git add server/src/routes/devices.ts server/src/app.ts server/test/devices-routes.test.ts
git commit -m "feat(server): device list and deactivate endpoints"
```

---

### Task 8: Server wiring, public-key endpoint, env + README

Construct the token signer at boot (graceful if absent), serve the public key, and document the licensing surface + keygen + real test price ids. Deliverable: the server boots with licensing enabled when the keys are present (and still boots without them), and the public key is served.

**Files:**
- Modify: `server/src/server.ts`
- Create: `server/src/routes/entitlement-pubkey.ts`
- Modify: `server/src/app.ts` (register `entitlementPubkeyRoutes` in the licensing guard)
- Modify: `server/.env.example`
- Modify: `server/README.md`

**Interfaces:**
- Consumes: `loadTokenConfig`, `createTokenSigner`.
- Produces: `async function entitlementPubkeyRoutes(app)` — `GET /v1/entitlement/public-key` (text/plain PEM). No other new API.

- [ ] **Step 1: Implement `server/src/routes/entitlement-pubkey.ts`**

```ts
import type { FastifyInstance } from 'fastify';

export async function entitlementPubkeyRoutes(app: FastifyInstance): Promise<void> {
  // The desktop app embeds this key to verify tokens offline; served here for
  // the build pipeline / ops convenience. Public key only — safe to expose.
  app.get('/v1/entitlement/public-key', async (_req, reply) => {
    return reply.header('content-type', 'text/plain; charset=utf-8').send(app.tokenSigner.publicKeyPem);
  });
}
```

- [ ] **Step 2: Register in `server/src/app.ts`** — import + one registration line in the licensing guard:

```ts
import { entitlementPubkeyRoutes } from './routes/entitlement-pubkey.js';
```
```ts
    app.register(deviceRoutes);
    app.register(entitlementPubkeyRoutes);
```

- [ ] **Step 3: Modify `server/src/server.ts`** — build the signer when configured. After the existing billing try/catch block and before `const app = buildApp(...)`, add:

```ts
import { loadTokenConfig } from './tokens/config.js';
import { createTokenSigner } from './tokens/signer.js';
```

```ts
// Licensing (entitlement tokens) is optional at boot too: if the Ed25519 env
// isn't set, start without token/auth routes rather than crashing.
let tokenSigner;
try {
  tokenSigner = await createTokenSigner(loadTokenConfig());
} catch (err) {
  tokenSigner = undefined;
}
```

Then pass `tokenSigner` into `buildApp({ pool, stripe, billing, tokenSigner, logger: { level: config.logLevel } })`, and after the existing billing warning add:

```ts
if (!tokenSigner) {
  app.log.warn('licensing disabled: entitlement keys not set (set ENTITLEMENT_ED25519_* to enable /v1/token, /v1/auth/*)');
}
```

Note: `server.ts` already uses top-level `await` (Phase 1), so `await createTokenSigner(...)` at module top level is fine.

- [ ] **Step 4: Build + boot regressions**

Run: `npm --prefix server run build`
Boot WITHOUT licensing env (only base + no ENTITLEMENT_*), confirm `/health` and the "licensing disabled" warning:

```bash
env NODE_ENV=development PORT=8080 HOST=127.0.0.1 LOG_LEVEL=info \
  DATABASE_URL="$(grep '^DATABASE_URL=' server/.env | cut -d= -f2-)" \
  node server/dist/server.js &
sleep 1
curl -s localhost:8080/health          # {"status":"ok","db":"up"}
curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/v1/entitlement/public-key  # 404 (licensing off)
kill %1
```

Expected: health ok; the pubkey route is absent (404) because licensing is disabled; logs show "licensing disabled". Capture outputs. (A full licensing-on boot needs generated keys — that is the operator flow in the README; the route behavior is already covered by tests via `buildApp` with a signer.)

- [ ] **Step 5: Extend `server/.env.example`** — append a licensing section:

```dotenv

# --- Entitlement tokens (licensing) ---
# Base64-encoded Ed25519 PEM keypair. Generate with: npm run gen:entitlement-keys
# DEDICATED keypair — do NOT reuse the Sparkle update key.
ENTITLEMENT_ED25519_PRIVATE_KEY=base64_pkcs8_pem
ENTITLEMENT_ED25519_PUBLIC_KEY=base64_spki_pem
ENTITLEMENT_ISSUER=https://api.slipreel.app
ENTITLEMENT_TOKEN_TTL_DAYS=14
```

Also update the Stripe price-id lines already in `.env.example` with a comment noting the current Becoming Ventures TEST price ids (do NOT change the placeholder format; add a comment line above them):

```dotenv
# Current test-mode ids (Becoming Ventures): monthly price_1U8lMWJa6q311aT7GVrhrzrM,
# yearly price_1U8lMYJa6q311aT71vuov8ak, one-time price_1U8lMZJa6q311aT7YZbPvHMp
```

- [ ] **Step 6: Extend `server/README.md`** — append a "Licensing (auth + entitlement tokens)" section:

````markdown
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
````

- [ ] **Step 7: Final full suite + typecheck + build**

Run: `npm --prefix server run typecheck && npm --prefix server run build && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add server/src/server.ts server/src/routes/entitlement-pubkey.ts server/src/app.ts \
  server/.env.example server/README.md
git commit -m "feat(server): wire entitlement signer at boot, serve public key, docs"
```

---

## Self-Review

**Spec coverage (Phase 3 scope — spec §4 token, §5 entitlement/device endpoints, §8 auth):**
- Token format §4 (EdDSA, claims, 14d exp, dedicated key) → Task 1 + Task 6 (mint from effective entitlement). `updates_until`/`plan`/`status`/`export`/`device_id`/`seat_limit` all set. Public key embeddable → Task 8.
- §5 `POST /v1/token` + `/v1/token/refresh` → Task 6; `GET /v1/devices` + `DELETE /v1/devices/:id` → Task 7. Auth endpoints → passwordless variant (session-from-checkout Task 4, magic-link Task 5) — deviation documented.
- §8 auth flow (browser → session → token → deep link): the server half (session establishment + token minting) is Tasks 4-6; the web `/app-auth` page + `slipreel://` deep link are Phase 4/5 (out of scope here). Device fingerprint is supplied by the client as `fingerprint`.
- §6 schema: uses existing `users`/`entitlements`/`devices`; adds `sessions`/`magic_links` (Task 3). Seat logic uses `devices.unique(user_id,fingerprint)` from 0001.
- Out of scope (later phases): the web pages, the Flutter licensing module + export gate, a real email provider, password auth (replaced by passwordless), rate-limiting (spec §5 mentions it — deferred to the deploy/hardening phase; noted).

**Placeholder scan:** No TBD/TODO. The magic-link email is explicitly stubbed with a documented non-production `debug_token`; the real test price ids are concrete. Every code step carries complete code.

**Type consistency:** `TokenSigner` (`{publicKeyPem, mint(EntitlementClaims), verify}`) is identical across signer.ts, the helper, app.ts decoration, and every route. `EntitlementClaims` fields match the token route's `mint(...)` call and the spec's claim names (`export`, `updates_until`, `device_id`, `seat_limit`). `EffectiveEntitlement` (`{plan,status,updatesUntil,export}`) from Task 2 is consumed verbatim in Task 6's `mintFor`. `registerDevice` return union (`{ok:true,deviceId,refreshToken} | {ok:false,reason:'seat_limit',devices}`) matches Task 6's handler branches. `req.userId` augmentation (Task 4) is read in Tasks 6-7. `SESSION_COOKIE`/`setSessionCookie`/`clearSessionCookie` names match across cookie.ts, auth.ts, magic-link.ts. `buildApp` deps (`{pool, logger?, stripe?, billing?, tokenSigner?}`) match all call sites: Phase-1/2 tests (no tokenSigner → licensing off) and `makeLicensingApp` (all four → licensing on). Migration `0004` tables (`sessions`, `magic_links`) match the store queries.

**Cross-task DB note:** every route test re-runs migrations (0001–0004) after `resetDatabase`, so `sessions`/`magic_links` and the device unique index exist. Phase-1/2 tests are unaffected (licensing guard skipped without a tokenSigner).

---

## Execution Handoff

Choose how to execute — see the offer in chat.
