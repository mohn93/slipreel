# Stripe Test Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Stripe (test mode) to the `server/` API: a checkout endpoint (subscription + one-time), a customer-portal endpoint, and a signature-verified, idempotent webhook that syncs Stripe state into the `entitlements` table — so a purchase in Stripe test mode produces the correct entitlement rows.

**Architecture:** All Stripe access goes through the official `stripe` Node SDK, injected into the Fastify app via `buildApp` deps (like the pg pool) so tests never hit the network. Purchases are keyed to a `users` row created/looked-up by email at checkout (a Stripe customer is created alongside). The webhook verifies the Stripe signature over the RAW request body (via `fastify-raw-body`), then dispatches events to a pure entitlement-sync service that writes `entitlements`, guarded for idempotency by `processed_stripe_events`. Two new tests strategies: unit-test the sync service against synthetic event objects on the test DB, and test the webhook route end-to-end using the SDK's offline signing helper (`stripe.webhooks.generateTestHeaderString`).

**Tech Stack:** Node 22, TypeScript (ESM, NodeNext), Fastify 5, `pg`, `zod`, `vitest` (all from Phase 1), plus `stripe` (official SDK) and `fastify-raw-body`.

**Spec:** [docs/superpowers/specs/2026-08-26-stripe-licensing-design.md](../specs/2026-08-26-stripe-licensing-design.md) (§5 API surface, §6 schema, §7 Stripe setup)

**Builds on:** [docs/superpowers/plans/2026-08-26-vps-api-skeleton.md](2026-08-26-vps-api-skeleton.md) (Phase 1 — the `server/` skeleton, merged/PR #65).

## Global Constraints

- **Location & style:** all code under `server/`; TypeScript + ESM (`.js` extensions on relative imports), Node 22, Fastify 5. Follow Phase 1's patterns exactly.
- **Stripe SDK only:** every Stripe API call goes through the `stripe` package. No hand-rolled HTTP to Stripe.
- **Injected, never global:** the Stripe client is passed into `buildApp` deps and read as `app.stripe`; services receive it as a parameter. Tests inject fakes — no test may make a network call.
- **Test mode only:** all keys are `sk_test_…` / `whsec_…`; price ids are test-mode ids. Nothing in this plan touches live mode.
- **Webhook security:** the webhook route verifies `Stripe-Signature` against the RAW body via `stripe.webhooks.constructEvent`. Invalid signature → HTTP 400, no DB writes.
- **Idempotency:** every webhook event is recorded in `processed_stripe_events`; a re-delivered event is a no-op.
- **Secrets:** all Stripe secrets come from environment only; never committed. `.env`/`server/.env` stay gitignored (Phase 1 already ignores them).
- **Migrations:** forward-only; the next file is `server/migrations/0002_*.sql`. Never edit `0001`.
- **Backward compatibility:** `buildApp`'s new deps are OPTIONAL. With no `stripe`/`billing` provided, the app behaves exactly as Phase 1 (only `/health`), so existing tests and a keyless `npm run dev` keep working.
- **Git:** branch `feat/stripe-licensing` (continues Phase 1). Stage only files you created/changed.

## Deviations from spec (ruled for this plan)

- **Account creation timing:** the spec (§5) lists full auth endpoints (signup/login/password). Those are deferred to a later phase. Phase 2 creates/looks up a `users` row by **email** at checkout and creates the Stripe customer then; login/passwords are not built here. To allow a user row that exists before any password is set, migration `0002` makes `users.password_hash` **nullable**. This is forward-compatible with the browser-deep-link auth in the spec.
- **Portal identification:** `/v1/portal` is keyed by email in this phase (no sessions yet). A later auth phase will scope it to the logged-in user. Noted in the endpoint's code comment.

---

## File Structure

```
server/
  package.json                 # + stripe, fastify-raw-body deps; + stripe:bootstrap script
  .env.example                 # + Stripe keys, price ids, site url (documented)
  migrations/
    0002_billing.sql           # password_hash nullable; unique index on stripe_subscription_id
  src/
    ids.ts                     # newId(prefix) id generator
    billing/
      config.ts                # BillingConfig + loadBillingConfig(env)
      stripe.ts                # createStripeClient(secretKey) -> Stripe
      customers.ts             # findOrCreateUserByEmail(pool, stripe, email)
      entitlements.ts          # handleStripeEvent(pool, event) + status mapping
    routes/
      stripe-webhook.ts        # POST /v1/stripe/webhook (raw body, verify, dispatch)
      billing.ts               # POST /v1/checkout, POST /v1/portal
    app.ts                     # extend AppDeps with optional stripe + billing; register routes
    server.ts                  # construct stripe client + billing config, pass to buildApp
  scripts/
    bootstrap-stripe.ts        # one-time: create test products/prices, print price ids
  test/
    billing-config.test.ts     # loadBillingConfig (pure)
    ids.test.ts                # newId (pure)
    customers.test.ts          # findOrCreateUserByEmail (DB + fake stripe)
    entitlements.test.ts       # handleStripeEvent (DB, synthetic events)
    stripe-webhook.test.ts     # webhook route (signed payload, DB effect)
    billing-routes.test.ts     # checkout + portal (fake stripe)
  README.md                    # + Stripe test-mode section (bootstrap, stripe listen/trigger, test cards)
```

Each Stripe concern is its own file. `entitlements.ts` (the sync logic) is deliberately pure of Fastify/HTTP so it can be unit-tested directly against the DB.

---

### Task 1: Dependencies, id helper, billing config, Stripe client factory

Adds the two new deps and three small, pure, unit-tested building blocks: an id generator, the billing env config, and the Stripe client factory. Deliverable: `npm --prefix server test` passes the new pure tests; deps install cleanly.

**Files:**
- Modify: `server/package.json` (deps + one script)
- Create: `server/src/ids.ts`
- Create: `server/src/billing/config.ts`
- Create: `server/src/billing/stripe.ts`
- Create: `server/test/ids.test.ts`
- Create: `server/test/billing-config.test.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `function newId(prefix: string): string` — `${prefix}_<32 hex>`.
  - `type BillingConfig = { secretKey: string; webhookSecret: string; prices: { monthly: string; yearly: string; onetime: string }; successUrl: string; cancelUrl: string; portalReturnUrl: string }`
  - `function loadBillingConfig(env?: NodeJS.ProcessEnv): BillingConfig` — throws a readable error if any required var is missing.
  - `function createStripeClient(secretKey: string): Stripe`

- [ ] **Step 1: Add dependencies + script to `server/package.json`**

Add to `dependencies` (keep the existing three):

```json
    "fastify": "^5.2.0",
    "fastify-raw-body": "^5.0.0",
    "pg": "^8.13.1",
    "stripe": "^17.5.0",
    "zod": "^3.24.1"
```

Add to `scripts` (after `"migrate"`):

```json
    "stripe:bootstrap": "tsx scripts/bootstrap-stripe.ts",
```

Then install: `npm --prefix server install`
Expected: `stripe` and `fastify-raw-body` resolve and appear in `package-lock.json`.

- [ ] **Step 2: Write the failing test `server/test/ids.test.ts`**

```ts
import { describe, it, expect } from 'vitest';
import { newId } from '../src/ids.js';

describe('newId', () => {
  it('prefixes and produces 32 hex chars', () => {
    const id = newId('usr');
    expect(id).toMatch(/^usr_[0-9a-f]{32}$/);
  });

  it('is unique across calls', () => {
    const a = newId('dev');
    const b = newId('dev');
    expect(a).not.toBe(b);
  });
});
```

- [ ] **Step 3: Run it — expect FAIL** (`cannot import ../src/ids.js`)

Run: `npm --prefix server test -- ids`

- [ ] **Step 4: Implement `server/src/ids.ts`**

```ts
import { randomUUID } from 'node:crypto';

/** Prefixed identifier, e.g. newId('usr') -> 'usr_3f2a...'. */
export function newId(prefix: string): string {
  return `${prefix}_${randomUUID().replace(/-/g, '')}`;
}
```

- [ ] **Step 5: Run it — expect PASS (2 tests)**

Run: `npm --prefix server test -- ids`

- [ ] **Step 6: Write the failing test `server/test/billing-config.test.ts`**

```ts
import { describe, it, expect } from 'vitest';
import { loadBillingConfig } from '../src/billing/config.js';

const base = {
  STRIPE_SECRET_KEY: 'sk_test_x',
  STRIPE_WEBHOOK_SECRET: 'whsec_x',
  STRIPE_PRICE_MONTHLY: 'price_m',
  STRIPE_PRICE_YEARLY: 'price_y',
  STRIPE_PRICE_ONETIME: 'price_o',
};

describe('loadBillingConfig', () => {
  it('parses a valid billing environment and derives URLs from PUBLIC_SITE_URL', () => {
    const cfg = loadBillingConfig({ ...base, PUBLIC_SITE_URL: 'https://slipreel.app' });
    expect(cfg.secretKey).toBe('sk_test_x');
    expect(cfg.webhookSecret).toBe('whsec_x');
    expect(cfg.prices).toEqual({ monthly: 'price_m', yearly: 'price_y', onetime: 'price_o' });
    expect(cfg.successUrl).toBe('https://slipreel.app/success?session_id={CHECKOUT_SESSION_ID}');
    expect(cfg.cancelUrl).toBe('https://slipreel.app/pricing');
    expect(cfg.portalReturnUrl).toBe('https://slipreel.app/account');
  });

  it('defaults PUBLIC_SITE_URL to https://slipreel.app', () => {
    const cfg = loadBillingConfig(base);
    expect(cfg.cancelUrl).toBe('https://slipreel.app/pricing');
  });

  it('throws when a required Stripe var is missing', () => {
    const { STRIPE_WEBHOOK_SECRET, ...missing } = base;
    expect(() => loadBillingConfig(missing)).toThrow(/STRIPE_WEBHOOK_SECRET/);
  });
});
```

- [ ] **Step 7: Run it — expect FAIL**

Run: `npm --prefix server test -- billing-config`

- [ ] **Step 8: Implement `server/src/billing/config.ts`**

```ts
import { z } from 'zod';

const schema = z.object({
  STRIPE_SECRET_KEY: z.string().min(1, 'STRIPE_SECRET_KEY is required'),
  STRIPE_WEBHOOK_SECRET: z.string().min(1, 'STRIPE_WEBHOOK_SECRET is required'),
  STRIPE_PRICE_MONTHLY: z.string().min(1, 'STRIPE_PRICE_MONTHLY is required'),
  STRIPE_PRICE_YEARLY: z.string().min(1, 'STRIPE_PRICE_YEARLY is required'),
  STRIPE_PRICE_ONETIME: z.string().min(1, 'STRIPE_PRICE_ONETIME is required'),
  PUBLIC_SITE_URL: z.string().url().default('https://slipreel.app'),
});

export type BillingConfig = {
  secretKey: string;
  webhookSecret: string;
  prices: { monthly: string; yearly: string; onetime: string };
  successUrl: string;
  cancelUrl: string;
  portalReturnUrl: string;
};

export function loadBillingConfig(env: NodeJS.ProcessEnv = process.env): BillingConfig {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
      .join('; ');
    throw new Error(`Invalid billing configuration: ${issues}`);
  }
  const e = parsed.data;
  const site = e.PUBLIC_SITE_URL.replace(/\/$/, '');
  return {
    secretKey: e.STRIPE_SECRET_KEY,
    webhookSecret: e.STRIPE_WEBHOOK_SECRET,
    prices: { monthly: e.STRIPE_PRICE_MONTHLY, yearly: e.STRIPE_PRICE_YEARLY, onetime: e.STRIPE_PRICE_ONETIME },
    successUrl: `${site}/success?session_id={CHECKOUT_SESSION_ID}`,
    cancelUrl: `${site}/pricing`,
    portalReturnUrl: `${site}/account`,
  };
}
```

- [ ] **Step 9: Run it — expect PASS (3 tests)**

Run: `npm --prefix server test -- billing-config`

- [ ] **Step 10: Implement `server/src/billing/stripe.ts`** (no dedicated test — it's a one-line SDK constructor exercised by later route tests)

```ts
import Stripe from 'stripe';

/** Construct the Stripe client. apiVersion is intentionally omitted so the
 * account's default pinned version is used; pin it here if you need a specific
 * one. Used by server.ts (real boot) and scripts/bootstrap-stripe.ts. */
export function createStripeClient(secretKey: string): Stripe {
  return new Stripe(secretKey);
}
```

- [ ] **Step 11: Typecheck + full suite**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`
Expected: no type errors; all tests pass (existing 11 + ids 2 + billing-config 3).

- [ ] **Step 12: Commit**

```bash
git add server/package.json server/package-lock.json server/src/ids.ts \
  server/src/billing/config.ts server/src/billing/stripe.ts \
  server/test/ids.test.ts server/test/billing-config.test.ts
git commit -m "feat(server): add stripe deps, id helper, billing config"
```

---

### Task 2: Migration 0002 + customer/user service

Adds the schema tweaks billing needs and the email-keyed user+Stripe-customer upsert. Deliverable: a DB-backed test proves a user + Stripe customer are created once and reused thereafter.

**Files:**
- Create: `server/migrations/0002_billing.sql`
- Create: `server/src/billing/customers.ts`
- Create: `server/test/customers.test.ts`

**Interfaces:**
- Consumes: `runMigrations`, `testPool`, `resetDatabase` (Phase 1); `newId` (Task 1).
- Produces:
  - `async function findOrCreateUserByEmail(pool: pg.Pool, stripe: Stripe, email: string): Promise<{ userId: string; stripeCustomerId: string }>`

- [ ] **Step 1: Write `server/migrations/0002_billing.sql`**

```sql
-- A user row can exist before any password is set (created at checkout).
ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL;

-- Enable upsert of a subscription entitlement keyed by its Stripe id.
CREATE UNIQUE INDEX entitlements_stripe_subscription_id_key
  ON entitlements (stripe_subscription_id)
  WHERE stripe_subscription_id IS NOT NULL;
```

- [ ] **Step 2: Write the failing test `server/test/customers.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import type Stripe from 'stripe';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { findOrCreateUserByEmail } from '../src/billing/customers.js';

/** Minimal fake Stripe that records customer.create calls. */
function fakeStripe(): { stripe: Stripe; created: string[] } {
  const created: string[] = [];
  let n = 0;
  const stripe = {
    customers: {
      create: async ({ email }: { email: string }) => {
        created.push(email);
        return { id: `cus_test_${++n}` };
      },
    },
  } as unknown as Stripe;
  return { stripe, created };
}

describe('findOrCreateUserByEmail', () => {
  let pool: pg.Pool;

  beforeAll(async () => {
    pool = testPool();
    await resetDatabase(pool);
    await runMigrations(pool);
  });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => { await pool.query('DELETE FROM users'); });

  it('creates a user and Stripe customer the first time', async () => {
    const { stripe, created } = fakeStripe();
    const r = await findOrCreateUserByEmail(pool, stripe, 'a@example.com');
    expect(r.userId).toMatch(/^usr_/);
    expect(r.stripeCustomerId).toBe('cus_test_1');
    expect(created).toEqual(['a@example.com']);

    const { rows } = await pool.query('SELECT email, stripe_customer_id, password_hash FROM users');
    expect(rows).toHaveLength(1);
    expect(rows[0].stripe_customer_id).toBe('cus_test_1');
    expect(rows[0].password_hash).toBeNull();
  });

  it('reuses the existing user + customer on a second call (case-insensitive email)', async () => {
    const { stripe, created } = fakeStripe();
    const first = await findOrCreateUserByEmail(pool, stripe, 'b@example.com');
    const second = await findOrCreateUserByEmail(pool, stripe, 'B@EXAMPLE.COM');
    expect(second.userId).toBe(first.userId);
    expect(second.stripeCustomerId).toBe(first.stripeCustomerId);
    expect(created).toEqual(['b@example.com']); // customer created only once
  });
});
```

- [ ] **Step 3: Run it — expect FAIL**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- customers`

- [ ] **Step 4: Implement `server/src/billing/customers.ts`**

```ts
import type pg from 'pg';
import type Stripe from 'stripe';
import { newId } from '../ids.js';

/**
 * Look up a user by email (the `email` column is citext, so match is
 * case-insensitive), creating the user row and a Stripe customer if absent.
 * Returns the internal user id and the Stripe customer id.
 */
export async function findOrCreateUserByEmail(
  pool: pg.Pool,
  stripe: Stripe,
  email: string,
): Promise<{ userId: string; stripeCustomerId: string }> {
  const existing = await pool.query<{ id: string; stripe_customer_id: string | null }>(
    'SELECT id, stripe_customer_id FROM users WHERE email = $1',
    [email],
  );

  if (existing.rows.length > 0) {
    const row = existing.rows[0]!;
    if (row.stripe_customer_id) {
      return { userId: row.id, stripeCustomerId: row.stripe_customer_id };
    }
    const customer = await stripe.customers.create({ email });
    await pool.query('UPDATE users SET stripe_customer_id = $1 WHERE id = $2', [customer.id, row.id]);
    return { userId: row.id, stripeCustomerId: customer.id };
  }

  const customer = await stripe.customers.create({ email });
  const userId = newId('usr');
  await pool.query(
    'INSERT INTO users (id, email, stripe_customer_id) VALUES ($1, $2, $3)',
    [userId, email, customer.id],
  );
  return { userId, stripeCustomerId: customer.id };
}
```

- [ ] **Step 5: Run it — expect PASS (2 tests)**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- customers`

- [ ] **Step 6: Full suite + typecheck**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`
Expected: green (migrate test still passes now that 0002 exists — it asserts 0001 applied and the table set, which is unaffected).

- [ ] **Step 7: Commit**

```bash
git add server/migrations/0002_billing.sql server/src/billing/customers.ts server/test/customers.test.ts
git commit -m "feat(server): billing migration and email-keyed customer upsert"
```

---

### Task 3: Entitlement sync service

The core logic: turn Stripe events into `entitlements` rows, idempotently. Deliverable: DB-backed tests prove one-time purchases set/extend `updates_until`, subscriptions map status + period, and a re-delivered event is a no-op.

**Files:**
- Create: `server/src/billing/entitlements.ts`
- Create: `server/test/entitlements.test.ts`

**Interfaces:**
- Consumes: the DB; `newId` (Task 1). Takes `Stripe.Event` objects.
- Produces:
  - `async function handleStripeEvent(pool: pg.Pool, event: Stripe.Event): Promise<{ processed: boolean }>` — returns `{processed:false}` if the event id was already recorded (idempotent skip), else applies it and returns `{processed:true}`.
  - `function mapSubscriptionStatus(stripeStatus: string): 'active' | 'grace' | 'canceled' | 'incomplete'` (exported for the test).

- [ ] **Step 1: Write the failing test `server/test/entitlements.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import type Stripe from 'stripe';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { handleStripeEvent, mapSubscriptionStatus } from '../src/billing/entitlements.js';

// Helper: seed a user with a known Stripe customer id.
async function seedUser(pool: pg.Pool, customerId: string): Promise<string> {
  const id = `usr_${customerId}`;
  await pool.query(
    'INSERT INTO users (id, email, stripe_customer_id) VALUES ($1, $2, $3)',
    [id, `${customerId}@example.com`, customerId],
  );
  return id;
}

// Build a minimal Stripe.Event of a given type/object. Cast through unknown —
// tests only touch the fields the service reads.
function event(id: string, type: string, object: unknown): Stripe.Event {
  return { id, type, data: { object } } as unknown as Stripe.Event;
}

describe('mapSubscriptionStatus', () => {
  it('maps stripe statuses to entitlement statuses', () => {
    expect(mapSubscriptionStatus('active')).toBe('active');
    expect(mapSubscriptionStatus('trialing')).toBe('active');
    expect(mapSubscriptionStatus('past_due')).toBe('grace');
    expect(mapSubscriptionStatus('unpaid')).toBe('grace');
    expect(mapSubscriptionStatus('canceled')).toBe('canceled');
    expect(mapSubscriptionStatus('incomplete')).toBe('incomplete');
  });
});

describe('handleStripeEvent', () => {
  let pool: pg.Pool;
  beforeAll(async () => {
    pool = testPool();
    await resetDatabase(pool);
    await runMigrations(pool);
  });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM processed_stripe_events');
    await pool.query('DELETE FROM entitlements');
    await pool.query('DELETE FROM users');
  });

  it('one-time checkout creates a onetime entitlement ~1 year out', async () => {
    await seedUser(pool, 'cus_ot');
    const r = await handleStripeEvent(
      pool,
      event('evt_1', 'checkout.session.completed', {
        mode: 'payment', customer: 'cus_ot', payment_intent: 'pi_1',
      }),
    );
    expect(r.processed).toBe(true);
    const { rows } = await pool.query(
      `SELECT plan, status, updates_until, stripe_payment_intent_id
       FROM entitlements WHERE plan = 'onetime'`,
    );
    expect(rows).toHaveLength(1);
    expect(rows[0].status).toBe('active');
    expect(rows[0].stripe_payment_intent_id).toBe('pi_1');
    const days = (new Date(rows[0].updates_until).getTime() - Date.now()) / 86_400_000;
    expect(days).toBeGreaterThan(360);
    expect(days).toBeLessThan(370);
  });

  it('a second one-time purchase extends updates_until by another year', async () => {
    await seedUser(pool, 'cus_ot');
    await handleStripeEvent(pool, event('evt_a', 'checkout.session.completed',
      { mode: 'payment', customer: 'cus_ot', payment_intent: 'pi_a' }));
    await handleStripeEvent(pool, event('evt_b', 'checkout.session.completed',
      { mode: 'payment', customer: 'cus_ot', payment_intent: 'pi_b' }));
    const { rows } = await pool.query(
      `SELECT updates_until FROM entitlements WHERE plan = 'onetime'`);
    expect(rows).toHaveLength(1);
    const days = (new Date(rows[0].updates_until).getTime() - Date.now()) / 86_400_000;
    expect(days).toBeGreaterThan(720);
    expect(days).toBeLessThan(740);
  });

  it('subscription.created upserts an active subscription entitlement with period end', async () => {
    await seedUser(pool, 'cus_sub');
    const periodEnd = Math.floor(Date.now() / 1000) + 30 * 86_400;
    await handleStripeEvent(pool, event('evt_s1', 'customer.subscription.created', {
      id: 'sub_1', customer: 'cus_sub', status: 'active', current_period_end: periodEnd,
    }));
    const { rows } = await pool.query(
      `SELECT plan, status, stripe_subscription_id, current_period_end
       FROM entitlements WHERE plan = 'subscription'`);
    expect(rows).toHaveLength(1);
    expect(rows[0].status).toBe('active');
    expect(rows[0].stripe_subscription_id).toBe('sub_1');
    expect(Math.abs(new Date(rows[0].current_period_end).getTime() - periodEnd * 1000)).toBeLessThan(2000);
  });

  it('subscription.updated to past_due moves status to grace (no duplicate row)', async () => {
    await seedUser(pool, 'cus_sub');
    const pe = Math.floor(Date.now() / 1000) + 30 * 86_400;
    await handleStripeEvent(pool, event('evt_s1', 'customer.subscription.created',
      { id: 'sub_1', customer: 'cus_sub', status: 'active', current_period_end: pe }));
    await handleStripeEvent(pool, event('evt_s2', 'customer.subscription.updated',
      { id: 'sub_1', customer: 'cus_sub', status: 'past_due', current_period_end: pe }));
    const { rows } = await pool.query(
      `SELECT status FROM entitlements WHERE stripe_subscription_id = 'sub_1'`);
    expect(rows).toHaveLength(1);
    expect(rows[0].status).toBe('grace');
  });

  it('subscription.deleted marks the entitlement canceled', async () => {
    await seedUser(pool, 'cus_sub');
    const pe = Math.floor(Date.now() / 1000) + 30 * 86_400;
    await handleStripeEvent(pool, event('evt_s1', 'customer.subscription.created',
      { id: 'sub_1', customer: 'cus_sub', status: 'active', current_period_end: pe }));
    await handleStripeEvent(pool, event('evt_s3', 'customer.subscription.deleted',
      { id: 'sub_1', customer: 'cus_sub', status: 'canceled', current_period_end: pe }));
    const { rows } = await pool.query(
      `SELECT status FROM entitlements WHERE stripe_subscription_id = 'sub_1'`);
    expect(rows[0].status).toBe('canceled');
  });

  it('is idempotent — re-delivering the same event id is a no-op', async () => {
    await seedUser(pool, 'cus_ot');
    const e = event('evt_dup', 'checkout.session.completed',
      { mode: 'payment', customer: 'cus_ot', payment_intent: 'pi_x' });
    const first = await handleStripeEvent(pool, e);
    const second = await handleStripeEvent(pool, e);
    expect(first.processed).toBe(true);
    expect(second.processed).toBe(false);
    const { rows } = await pool.query(`SELECT count(*)::int AS n FROM entitlements`);
    expect(rows[0].n).toBe(1);
  });

  it('ignores unrelated event types without error', async () => {
    const r = await handleStripeEvent(pool, event('evt_ping', 'ping', {}));
    expect(r.processed).toBe(true); // recorded as seen, no entitlement change
    const { rows } = await pool.query(`SELECT count(*)::int AS n FROM entitlements`);
    expect(rows[0].n).toBe(0);
  });
});
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- entitlements`

- [ ] **Step 3: Implement `server/src/billing/entitlements.ts`**

```ts
import type pg from 'pg';
import type Stripe from 'stripe';
import { newId } from '../ids.js';

export function mapSubscriptionStatus(
  stripeStatus: string,
): 'active' | 'grace' | 'canceled' | 'incomplete' {
  switch (stripeStatus) {
    case 'active':
    case 'trialing':
      return 'active';
    case 'past_due':
    case 'unpaid':
      return 'grace';
    case 'canceled':
      return 'canceled';
    default:
      return 'incomplete';
  }
}

/** Resolve our user id from a Stripe customer id; null if unknown. */
async function userIdForCustomer(pool: pg.Pool, customer: unknown): Promise<string | null> {
  if (typeof customer !== 'string') return null;
  const { rows } = await pool.query<{ id: string }>(
    'SELECT id FROM users WHERE stripe_customer_id = $1',
    [customer],
  );
  return rows[0]?.id ?? null;
}

/**
 * Apply a Stripe event to the entitlements table, idempotently. The first time
 * an event id is seen it is recorded in processed_stripe_events and applied;
 * subsequent deliveries are skipped. Unknown event types are recorded and
 * ignored.
 */
export async function handleStripeEvent(
  pool: pg.Pool,
  event: Stripe.Event,
): Promise<{ processed: boolean }> {
  // Idempotency gate: claim the event id, or bail if already claimed.
  const claim = await pool.query(
    'INSERT INTO processed_stripe_events (event_id) VALUES ($1) ON CONFLICT DO NOTHING RETURNING event_id',
    [event.id],
  );
  if (claim.rowCount === 0) return { processed: false };

  switch (event.type) {
    case 'checkout.session.completed': {
      const s = event.data.object as Stripe.Checkout.Session;
      if (s.mode === 'payment') {
        const userId = await userIdForCustomer(pool, s.customer);
        if (userId) await extendOnetime(pool, userId, s.payment_intent);
      }
      // subscription-mode checkouts are handled by the subscription.* events.
      break;
    }
    case 'customer.subscription.created':
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted': {
      const sub = event.data.object as Stripe.Subscription;
      const userId = await userIdForCustomer(pool, sub.customer);
      if (userId) await upsertSubscription(pool, userId, sub);
      break;
    }
    default:
      // Recorded above; nothing to apply.
      break;
  }
  return { processed: true };
}

async function extendOnetime(
  pool: pg.Pool,
  userId: string,
  paymentIntent: unknown,
): Promise<void> {
  const pi = typeof paymentIntent === 'string' ? paymentIntent : null;
  const existing = await pool.query<{ id: string }>(
    `SELECT id FROM entitlements WHERE user_id = $1 AND plan = 'onetime'`,
    [userId],
  );
  if (existing.rows.length > 0) {
    // Extend from the later of now or the current ceiling, by one year.
    await pool.query(
      `UPDATE entitlements
         SET updates_until = GREATEST(updates_until, now()) + interval '1 year',
             status = 'active',
             stripe_payment_intent_id = $2,
             updated_at = now()
       WHERE id = $1`,
      [existing.rows[0]!.id, pi],
    );
  } else {
    await pool.query(
      `INSERT INTO entitlements
         (id, user_id, plan, status, stripe_payment_intent_id, updates_until)
       VALUES ($1, $2, 'onetime', 'active', $3, now() + interval '1 year')`,
      [newId('ent'), userId, pi],
    );
  }
}

async function upsertSubscription(
  pool: pg.Pool,
  userId: string,
  sub: Stripe.Subscription,
): Promise<void> {
  const status = mapSubscriptionStatus(sub.status);
  const periodEnd = new Date(sub.current_period_end * 1000);
  await pool.query(
    `INSERT INTO entitlements
       (id, user_id, plan, status, stripe_subscription_id, current_period_end)
     VALUES ($1, $2, 'subscription', $3, $4, $5)
     ON CONFLICT (stripe_subscription_id) WHERE stripe_subscription_id IS NOT NULL
     DO UPDATE SET status = EXCLUDED.status,
                   current_period_end = EXCLUDED.current_period_end,
                   updated_at = now()`,
    [newId('ent'), userId, status, sub.id, periodEnd],
  );
}
```

**Stripe SDK note (`current_period_end`):** in recent Stripe API versions this field moved off the `Subscription` object onto its items (`sub.items.data[0].current_period_end`). The synthetic test events above put it at the top level, and `upsertSubscription` reads `sub.current_period_end` to match. If `npm run typecheck` reports `current_period_end` is not on `Stripe.Subscription`, read it defensively instead — `const epoch = (sub as any).current_period_end ?? sub.items?.data?.[0]?.current_period_end;` — and keep the synthetic test objects as written (top-level), so the tests still drive the same value. Do not change the test shape; adapt only the field access in the implementation.

- [ ] **Step 4: Run it — expect PASS (all cases)**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- entitlements`

Note: the `ON CONFLICT ... WHERE` partial-index inference requires Postgres to match the exact predicate from migration 0002 (`WHERE stripe_subscription_id IS NOT NULL`) — it does. If PG rejects the inference syntax, use `ON CONFLICT ON CONSTRAINT entitlements_stripe_subscription_id_key` — but the index is not a named constraint, so keep the predicate form.

- [ ] **Step 5: Full suite + typecheck**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`

- [ ] **Step 6: Commit**

```bash
git add server/src/billing/entitlements.ts server/test/entitlements.test.ts
git commit -m "feat(server): entitlement sync from stripe events (idempotent)"
```

---

### Task 4: Webhook route + buildApp deps extension

Wires the Stripe client + billing config into `buildApp` (optional, backward-compatible) and adds the signature-verified webhook. Deliverable: tests prove a validly-signed event mutates the DB and an invalid signature returns 400 with no writes.

**Files:**
- Modify: `server/src/app.ts`
- Create: `server/src/routes/stripe-webhook.ts`
- Create: `server/test/stripe-webhook.test.ts`

**Interfaces:**
- Consumes: `handleStripeEvent` (Task 3); `BillingConfig` (Task 1); `createStripeClient` (Task 1); `fastify-raw-body`.
- Produces:
  - Extended `type AppDeps = { pool: pg.Pool; logger?: FastifyServerOptions['logger']; stripe?: Stripe; billing?: BillingConfig }`.
  - `app.stripe: Stripe` and `app.billing: BillingConfig` decorations (present only when the deps were provided).
  - `async function stripeWebhookRoutes(app: FastifyInstance): Promise<void>` registering `POST /v1/stripe/webhook`.

- [ ] **Step 1: Write the failing test `server/test/stripe-webhook.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import Stripe from 'stripe';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { buildApp } from '../src/app.js';
import type { BillingConfig } from '../src/billing/config.js';

const WHSEC = 'whsec_test_secret';
// Stripe's constructEvent/generateTestHeaderString are pure crypto — no network.
const stripe = new Stripe('sk_test_dummy');

const billing: BillingConfig = {
  secretKey: 'sk_test_dummy', webhookSecret: WHSEC,
  prices: { monthly: 'price_m', yearly: 'price_y', onetime: 'price_o' },
  successUrl: 'https://slipreel.app/success', cancelUrl: 'https://slipreel.app/pricing',
  portalReturnUrl: 'https://slipreel.app/account',
};

function signed(body: object): { payload: string; header: string } {
  const payload = JSON.stringify(body);
  const header = stripe.webhooks.generateTestHeaderString({ payload, secret: WHSEC });
  return { payload, header };
}

describe('POST /v1/stripe/webhook', () => {
  let pool: pg.Pool;
  let app: FastifyInstance;

  beforeAll(async () => {
    pool = testPool();
    await resetDatabase(pool);
    await runMigrations(pool);
    await pool.query(
      `INSERT INTO users (id, email, stripe_customer_id) VALUES ('usr_wh', 'wh@example.com', 'cus_wh')`);
    app = buildApp({ pool, stripe, billing, logger: false });
    await app.ready();
  });
  afterAll(async () => { await app.close(); await pool.end(); });

  it('accepts a validly-signed event and applies it', async () => {
    const { payload, header } = signed({
      id: 'evt_wh_1', type: 'checkout.session.completed',
      data: { object: { mode: 'payment', customer: 'cus_wh', payment_intent: 'pi_wh' } },
    });
    const res = await app.inject({
      method: 'POST', url: '/v1/stripe/webhook',
      headers: { 'stripe-signature': header, 'content-type': 'application/json' },
      payload,
    });
    expect(res.statusCode).toBe(200);
    const { rows } = await pool.query(
      `SELECT plan FROM entitlements WHERE user_id = 'usr_wh'`);
    expect(rows).toHaveLength(1);
    expect(rows[0].plan).toBe('onetime');
  });

  it('rejects a bad signature with 400 and writes nothing', async () => {
    const payload = JSON.stringify({
      id: 'evt_wh_2', type: 'checkout.session.completed',
      data: { object: { mode: 'payment', customer: 'cus_wh', payment_intent: 'pi_bad' } },
    });
    const res = await app.inject({
      method: 'POST', url: '/v1/stripe/webhook',
      headers: { 'stripe-signature': 't=1,v1=deadbeef', 'content-type': 'application/json' },
      payload,
    });
    expect(res.statusCode).toBe(400);
    const { rows } = await pool.query(
      `SELECT event_id FROM processed_stripe_events WHERE event_id = 'evt_wh_2'`);
    expect(rows).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run it — expect FAIL** (buildApp doesn't accept stripe/billing; route missing)

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- stripe-webhook`

- [ ] **Step 3: Implement `server/src/routes/stripe-webhook.ts`**

```ts
import type { FastifyInstance } from 'fastify';
import { handleStripeEvent } from '../billing/entitlements.js';

export async function stripeWebhookRoutes(app: FastifyInstance): Promise<void> {
  app.post(
    '/v1/stripe/webhook',
    { config: { rawBody: true } },
    async (req, reply) => {
      const sig = req.headers['stripe-signature'];
      if (typeof sig !== 'string' || typeof req.rawBody !== 'string') {
        return reply.code(400).send({ error: 'missing signature or body' });
      }
      let evt;
      try {
        evt = app.stripe.webhooks.constructEvent(req.rawBody, sig, app.billing.webhookSecret);
      } catch (err) {
        app.log.warn({ err }, 'stripe webhook signature verification failed');
        return reply.code(400).send({ error: 'invalid signature' });
      }
      try {
        await handleStripeEvent(app.pool, evt);
      } catch (err) {
        app.log.error({ err, type: evt.type }, 'stripe webhook handler failed');
        return reply.code(500).send({ error: 'handler error' });
      }
      return reply.code(200).send({ received: true });
    },
  );
}
```

- [ ] **Step 4: Modify `server/src/app.ts`** — extend deps, register raw-body + billing routes when configured.

Replace the file with:

```ts
import Fastify, { type FastifyInstance, type FastifyServerOptions } from 'fastify';
import rawBody from 'fastify-raw-body';
import type pg from 'pg';
import type Stripe from 'stripe';
import { healthRoutes } from './routes/health.js';
import { stripeWebhookRoutes } from './routes/stripe-webhook.js';
import type { BillingConfig } from './billing/config.js';

declare module 'fastify' {
  interface FastifyInstance {
    pool: pg.Pool;
    stripe: Stripe;
    billing: BillingConfig;
  }
}

export type AppDeps = {
  pool: pg.Pool;
  logger?: FastifyServerOptions['logger'];
  stripe?: Stripe;
  billing?: BillingConfig;
};

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({
    logger: deps.logger ?? true,
    // Trust X-Forwarded-* only from the co-located nginx on loopback.
    trustProxy: 'loopback',
  });

  app.decorate('pool', deps.pool);
  app.register(healthRoutes);

  // Billing is optional: with no stripe client + config the app is Phase-1
  // behaviour (only /health), so keyless dev and existing tests still work.
  if (deps.stripe && deps.billing) {
    app.decorate('stripe', deps.stripe);
    app.decorate('billing', deps.billing);
    // Raw body needed so the webhook can verify Stripe's signature over bytes.
    app.register(rawBody, { field: 'rawBody', global: false, encoding: 'utf8', runFirst: true });
    app.register(stripeWebhookRoutes);
  }

  return app;
}
```

- [ ] **Step 5: Run it — expect PASS (2 tests)**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- stripe-webhook`

- [ ] **Step 6: Full suite + typecheck** (existing health tests must still pass — they call `buildApp({pool, logger})` with no stripe, so billing routes aren't registered)

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`

- [ ] **Step 7: Commit**

```bash
git add server/src/app.ts server/src/routes/stripe-webhook.ts server/test/stripe-webhook.test.ts
git commit -m "feat(server): signature-verified stripe webhook endpoint"
```

---

### Task 5: Checkout + portal routes

The two purchase-initiation endpoints. Deliverable: tests prove `/v1/checkout` creates a session with the right price/mode and returns its url, and `/v1/portal` returns a portal url (or 404 for an unknown email), using an injected fake Stripe.

**Files:**
- Create: `server/src/routes/billing.ts`
- Modify: `server/src/app.ts` (register `billingRoutes` in the same billing guard)
- Create: `server/test/billing-routes.test.ts`

**Interfaces:**
- Consumes: `findOrCreateUserByEmail` (Task 2); `app.stripe`, `app.billing` (Task 4).
- Produces:
  - `async function billingRoutes(app: FastifyInstance): Promise<void>` registering `POST /v1/checkout` and `POST /v1/portal`.

- [ ] **Step 1: Write the failing test `server/test/billing-routes.test.ts`**

```ts
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import type Stripe from 'stripe';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { buildApp } from '../src/app.js';
import type { BillingConfig } from '../src/billing/config.js';

const billing: BillingConfig = {
  secretKey: 'sk_test_dummy', webhookSecret: 'whsec_x',
  prices: { monthly: 'price_m', yearly: 'price_y', onetime: 'price_o' },
  successUrl: 'https://slipreel.app/success?session_id={CHECKOUT_SESSION_ID}',
  cancelUrl: 'https://slipreel.app/pricing',
  portalReturnUrl: 'https://slipreel.app/account',
};

// Fake Stripe recording the args of the calls the routes make.
function fakeStripe() {
  const calls: { checkout?: any; portal?: any; customerCreated?: string[] } = { customerCreated: [] };
  let n = 0;
  const stripe = {
    customers: { create: async ({ email }: { email: string }) => {
      calls.customerCreated!.push(email); return { id: `cus_${++n}` };
    } },
    checkout: { sessions: { create: async (args: any) => {
      calls.checkout = args; return { id: 'cs_1', url: 'https://checkout.stripe.test/cs_1' };
    } } },
    billingPortal: { sessions: { create: async (args: any) => {
      calls.portal = args; return { id: 'bps_1', url: 'https://portal.stripe.test/bps_1' };
    } } },
  } as unknown as Stripe;
  return { stripe, calls };
}

describe('billing routes', () => {
  let pool: pg.Pool;
  beforeAll(async () => {
    pool = testPool(); await resetDatabase(pool); await runMigrations(pool);
  });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => { await pool.query('DELETE FROM users'); });

  async function make(stripe: Stripe): Promise<FastifyInstance> {
    const app = buildApp({ pool, stripe, billing, logger: false });
    await app.ready();
    return app;
  }

  it('POST /v1/checkout (yearly) creates a subscription session and returns its url', async () => {
    const { stripe, calls } = fakeStripe();
    const app = await make(stripe);
    const res = await app.inject({ method: 'POST', url: '/v1/checkout',
      payload: { email: 'c@example.com', plan: 'yearly' } });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ url: 'https://checkout.stripe.test/cs_1' });
    expect(calls.checkout.mode).toBe('subscription');
    expect(calls.checkout.line_items[0].price).toBe('price_y');
    expect(calls.checkout.customer).toBe('cus_1');
    expect(calls.checkout.success_url).toBe(billing.successUrl);
    await app.close();
  });

  it('POST /v1/checkout (onetime) uses payment mode and the onetime price', async () => {
    const { stripe, calls } = fakeStripe();
    const app = await make(stripe);
    const res = await app.inject({ method: 'POST', url: '/v1/checkout',
      payload: { email: 'd@example.com', plan: 'onetime' } });
    expect(res.statusCode).toBe(200);
    expect(calls.checkout.mode).toBe('payment');
    expect(calls.checkout.line_items[0].price).toBe('price_o');
    await app.close();
  });

  it('POST /v1/checkout rejects an unknown plan with 400', async () => {
    const { stripe } = fakeStripe();
    const app = await make(stripe);
    const res = await app.inject({ method: 'POST', url: '/v1/checkout',
      payload: { email: 'e@example.com', plan: 'lifetime' } });
    expect(res.statusCode).toBe(400);
    await app.close();
  });

  it('POST /v1/portal returns a portal url for a known customer', async () => {
    const { stripe, calls } = fakeStripe();
    const app = await make(stripe);
    // create the user first via a checkout
    await app.inject({ method: 'POST', url: '/v1/checkout',
      payload: { email: 'f@example.com', plan: 'monthly' } });
    const res = await app.inject({ method: 'POST', url: '/v1/portal',
      payload: { email: 'f@example.com' } });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ url: 'https://portal.stripe.test/bps_1' });
    expect(calls.portal.return_url).toBe(billing.portalReturnUrl);
    await app.close();
  });

  it('POST /v1/portal 404s for an unknown email', async () => {
    const { stripe } = fakeStripe();
    const app = await make(stripe);
    const res = await app.inject({ method: 'POST', url: '/v1/portal',
      payload: { email: 'nobody@example.com' } });
    expect(res.statusCode).toBe(404);
    await app.close();
  });
});
```

- [ ] **Step 2: Run it — expect FAIL** (routes not registered)

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- billing-routes`

- [ ] **Step 3: Implement `server/src/routes/billing.ts`**

```ts
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { findOrCreateUserByEmail } from '../billing/customers.js';

const checkoutBody = z.object({
  email: z.string().email(),
  plan: z.enum(['monthly', 'yearly', 'onetime']),
});
const portalBody = z.object({ email: z.string().email() });

export async function billingRoutes(app: FastifyInstance): Promise<void> {
  app.post('/v1/checkout', async (req, reply) => {
    const parsed = checkoutBody.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'invalid request', detail: parsed.error.issues });
    }
    const { email, plan } = parsed.data;
    const { stripeCustomerId } = await findOrCreateUserByEmail(app.pool, app.stripe, email);
    const price = app.billing.prices[plan];
    const mode = plan === 'onetime' ? 'payment' : 'subscription';
    const session = await app.stripe.checkout.sessions.create({
      customer: stripeCustomerId,
      mode,
      line_items: [{ price, quantity: 1 }],
      success_url: app.billing.successUrl,
      cancel_url: app.billing.cancelUrl,
    });
    return reply.send({ url: session.url });
  });

  // NOTE: email-keyed for this phase; a later auth phase scopes this to the
  // authenticated user instead of trusting a posted email.
  app.post('/v1/portal', async (req, reply) => {
    const parsed = portalBody.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'invalid request' });
    }
    const { rows } = await app.pool.query<{ stripe_customer_id: string | null }>(
      'SELECT stripe_customer_id FROM users WHERE email = $1',
      [parsed.data.email],
    );
    const customer = rows[0]?.stripe_customer_id;
    if (!customer) return reply.code(404).send({ error: 'no customer for email' });
    const session = await app.stripe.billingPortal.sessions.create({
      customer,
      return_url: app.billing.portalReturnUrl,
    });
    return reply.send({ url: session.url });
  });
}
```

- [ ] **Step 4: Register `billingRoutes` in `server/src/app.ts`**

In the `if (deps.stripe && deps.billing) { … }` block, add the import and one registration line after `app.register(stripeWebhookRoutes);`:

```ts
import { billingRoutes } from './routes/billing.js';
```
```ts
    app.register(stripeWebhookRoutes);
    app.register(billingRoutes);
```

- [ ] **Step 5: Run it — expect PASS (5 tests)**

Run: `env $(grep -v '^#' server/.env | xargs) npm --prefix server test -- billing-routes`

- [ ] **Step 6: Full suite + typecheck**

Run: `npm --prefix server run typecheck && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`

- [ ] **Step 7: Commit**

```bash
git add server/src/routes/billing.ts server/src/app.ts server/test/billing-routes.test.ts
git commit -m "feat(server): checkout and customer-portal endpoints"
```

---

### Task 6: Server wiring, bootstrap script, env + README

Constructs the real Stripe client at boot, adds the one-time product/price bootstrap script, and documents the Stripe test-mode workflow. Deliverable: the server boots with billing enabled when Stripe env is present (and still boots without it), and an operator has a written runbook for test-mode setup.

**Files:**
- Modify: `server/src/server.ts`
- Create: `server/scripts/bootstrap-stripe.ts`
- Modify: `server/.env.example`
- Modify: `server/README.md`

**Interfaces:**
- Consumes: `loadBillingConfig`, `createStripeClient`, `buildApp` (with the new deps).
- Produces: no new exported API. The bootstrap script is a CLI.

- [ ] **Step 1: Modify `server/src/server.ts`** to wire billing when configured. Replace the config/pool/app construction block near the top with:

```ts
import { loadConfig } from './config.js';
import { createPool } from './db.js';
import { runMigrations } from './migrate.js';
import { buildApp } from './app.js';
import { loadBillingConfig } from './billing/config.js';
import { createStripeClient } from './billing/stripe.js';

const config = loadConfig();
const pool = createPool(config);

// Billing is optional at boot: if the Stripe env isn't set, start without the
// billing routes (only /health etc.) rather than crashing. This keeps a keyless
// dev box working while a fully-configured box gets checkout/portal/webhook.
let stripe;
let billing;
try {
  billing = loadBillingConfig();
  stripe = createStripeClient(billing.secretKey);
} catch (err) {
  billing = undefined;
  stripe = undefined;
}

const app = buildApp({
  pool,
  stripe,
  billing,
  logger: { level: config.logLevel },
});

if (!billing) {
  app.log.warn('billing disabled: Stripe env not fully configured (set STRIPE_* to enable checkout/webhook)');
}
```

Keep the existing `start()` function (migrate → listen → signal handlers) and the trailing `start().catch(...)` unchanged.

- [ ] **Step 2: Build + boot without Stripe env (regression: still serves /health)**

Run: `npm --prefix server run build`
Then boot with billing intentionally disabled and confirm the warning + health:

```bash
env NODE_ENV=development PORT=8080 HOST=127.0.0.1 LOG_LEVEL=info \
  DATABASE_URL="$(grep '^DATABASE_URL=' server/.env | cut -d= -f2-)" \
  node server/dist/server.js &
sleep 1
curl -s localhost:8080/health   # expect {"status":"ok","db":"up"}
kill %1
```

Expected: `/health` returns ok, and the logs contain the "billing disabled" warning (no Stripe env was passed). Clean up the process.

- [ ] **Step 3: Implement `server/scripts/bootstrap-stripe.ts`** (idempotent test-mode product/price creation)

```ts
/**
 * One-time (idempotent) creation of Slipreel's Stripe TEST-mode products and
 * prices. Run with your test secret key set:
 *   STRIPE_SECRET_KEY=sk_test_... npm run stripe:bootstrap
 * It prints the three price ids to paste into server/.env. Safe to re-run:
 * it looks up prices by lookup_key and only creates missing ones.
 *
 * Placeholder amounts (USD) — adjust before go-live:
 *   monthly 900 ($9), yearly 7900 ($79), one-time 9900 ($99).
 */
import Stripe from 'stripe';

const key = process.env.STRIPE_SECRET_KEY;
if (!key || !key.startsWith('sk_test_')) {
  console.error('Set STRIPE_SECRET_KEY to a sk_test_ key first (test mode only).');
  process.exit(1);
}
const stripe = new Stripe(key);

type Spec = {
  lookupKey: string;
  productName: string;
  amount: number;
  recurring?: 'month' | 'year';
};

const specs: Spec[] = [
  { lookupKey: 'slipreel_monthly', productName: 'Slipreel Pro (Monthly)', amount: 900, recurring: 'month' },
  { lookupKey: 'slipreel_yearly', productName: 'Slipreel Pro (Yearly)', amount: 7900, recurring: 'year' },
  { lookupKey: 'slipreel_onetime', productName: 'Slipreel Pro (One-time, 1 year of updates)', amount: 9900 },
];

async function ensurePrice(spec: Spec): Promise<string> {
  const existing = await stripe.prices.list({ lookup_keys: [spec.lookupKey], limit: 1 });
  if (existing.data.length > 0) return existing.data[0]!.id;

  const product = await stripe.products.create({ name: spec.productName });
  const price = await stripe.prices.create({
    product: product.id,
    unit_amount: spec.amount,
    currency: 'usd',
    lookup_key: spec.lookupKey,
    ...(spec.recurring ? { recurring: { interval: spec.recurring } } : {}),
  });
  return price.id;
}

const monthly = await ensurePrice(specs[0]!);
const yearly = await ensurePrice(specs[1]!);
const onetime = await ensurePrice(specs[2]!);

console.log('Add these to server/.env (test mode):');
console.log(`STRIPE_PRICE_MONTHLY=${monthly}`);
console.log(`STRIPE_PRICE_YEARLY=${yearly}`);
console.log(`STRIPE_PRICE_ONETIME=${onetime}`);
```

- [ ] **Step 4: Verify the bootstrap script type-checks and is runnable-shaped** (do NOT run it — it needs the user's Stripe test key)

Run: `npm --prefix server run typecheck`
Expected: clean. (Running the script is a user step — see README.)

- [ ] **Step 5: Extend `server/.env.example`** — append a Stripe section:

```dotenv

# --- Stripe (test mode) ---
# Test secret key from the Stripe dashboard (Developers -> API keys).
STRIPE_SECRET_KEY=sk_test_...
# Webhook signing secret. Local dev: from `stripe listen` output.
STRIPE_WEBHOOK_SECRET=whsec_...
# Price ids printed by `npm run stripe:bootstrap`.
STRIPE_PRICE_MONTHLY=price_...
STRIPE_PRICE_YEARLY=price_...
STRIPE_PRICE_ONETIME=price_...
# Base site URL used to build checkout success/cancel + portal return URLs.
PUBLIC_SITE_URL=https://slipreel.app
```

Also append `HOST`, `STRIPE_*`, `PUBLIC_SITE_URL` to your local `server/.env` so the dev server can enable billing (do NOT commit `server/.env`). For the STRIPE_PRICE_* in `server/.env` during tests, any placeholder is fine (tests inject their own billing config); real values come from the bootstrap script.

- [ ] **Step 6: Extend `server/README.md`** — add a "Stripe (test mode)" section after the existing content:

````markdown
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
````

- [ ] **Step 7: Final full suite + typecheck + build**

Run: `npm --prefix server run typecheck && npm --prefix server run build && env $(grep -v '^#' server/.env | xargs) npm --prefix server test`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add server/src/server.ts server/scripts/bootstrap-stripe.ts server/.env.example server/README.md
git commit -m "feat(server): wire stripe at boot, bootstrap script, test-mode docs"
```

---

## Self-Review

**Spec coverage (Phase 2 scope: spec §5 checkout/portal/webhook + device-less parts of §7):**
- `/v1/checkout` (sub + one-time) → Task 5. `/v1/portal` → Task 5. `/v1/stripe/webhook` (signature-verified, idempotent) → Task 4. Entitlement sync for the §7 event list (`checkout.session.completed`, `customer.subscription.created|updated|deleted`) → Task 3. Products/prices (§7) → Task 6 bootstrap script. Test-mode setup (`stripe listen`/`trigger`, test cards) → Task 6 README. Schema use of `users`/`entitlements`/`processed_stripe_events` (§6) → Tasks 2–3. Out of scope by design (deferred): auth endpoints, entitlement-token minting, device seats, `invoice.*` fine-grained handling (subscription.updated already covers active↔grace via status; a dedicated invoice handler is a later refinement — noted, not built).
- Deviations documented in the "Deviations from spec" section (email-keyed users, nullable password_hash, email-keyed portal).

**Placeholder scan:** No TBD/TODO. The bootstrap amounts are explicitly labelled placeholders (spec §15 left prices open), and the API-version omission is a deliberate, documented choice. Every code step carries complete code.

**Type consistency:** `BillingConfig` shape is identical across `config.ts`, the route files, `app.ts`, and every test. `findOrCreateUserByEmail(pool, stripe, email) -> {userId, stripeCustomerId}` matches its Task 5 call site. `handleStripeEvent(pool, event) -> {processed}` matches its Task 4 call site. `buildApp` deps (`{pool, logger?, stripe?, billing?}`) match all call sites: Phase-1 health test (`{pool, logger}`, billing off) and the new tests (`{pool, stripe, billing, logger}`, billing on). `app.stripe`/`app.billing` decorations declared once in `app.ts` and only read inside the billing guard's routes. `mapSubscriptionStatus` returns the same union the `entitlements.status` CHECK constraint allows.

**Cross-task DB note:** Tasks 3–5 each `runMigrations` (0001 + 0002) after `resetDatabase`, so the partial unique index used by the `ON CONFLICT` upsert exists in every DB-backed test. The migrate test from Phase 1 still passes (it asserts the table set, unaffected by 0002's index/nullable change).

---

## Execution Handoff

Choose how to execute — see the offer in chat.
