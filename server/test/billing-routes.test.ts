import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import type Stripe from 'stripe';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { buildApp } from '../src/app.js';
import type { BillingConfig } from '../src/billing/config.js';
import type { TokenSigner } from '../src/tokens/signer.js';
import { createSession } from '../src/auth/sessions.js';
import { makeTestSigner } from './helpers/licensing.js';

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
    checkout: { sessions: {
      create: async (args: any) => {
        calls.checkout = args; return { id: 'cs_1', url: 'https://checkout.stripe.test/cs_1' };
      },
      // The buyer's first customer is cus_1 (customers.create above), so a
      // completed session for cus_1 logs that same user in.
      retrieve: async (_id: string) => ({
        status: 'complete', customer: 'cus_1', created: Math.floor(Date.now() / 1000),
      }),
    } },
    billingPortal: { sessions: { create: async (args: any) => {
      calls.portal = args; return { id: 'bps_1', url: 'https://portal.stripe.test/bps_1' };
    } } },
  } as unknown as Stripe;
  return { stripe, calls };
}

describe('billing routes', () => {
  let pool: pg.Pool;
  let signer: TokenSigner;
  let cookie: string;
  beforeAll(async () => {
    pool = testPool(); await resetDatabase(pool); await runMigrations(pool);
    signer = await makeTestSigner();
  });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM sessions');
    await pool.query('DELETE FROM consumed_checkout_sessions');
    await pool.query('DELETE FROM users');
    await pool.query("INSERT INTO users (id,email,email_verified) VALUES ('buyer','buyer@example.com',true)");
    cookie = `slipreel_session=${(await createSession(pool,'buyer')).token}`;
  });

  // Wire the token signer so auth routes (session-from-checkout) are available:
  // /v1/portal is session-scoped, so the portal tests need to log a buyer in.
  async function make(stripe: Stripe): Promise<FastifyInstance> {
    const app = buildApp({ pool, stripe, billing, tokenSigner: signer, logger: false });
    await app.ready();
    return app;
  }

  it('rejects anonymous checkout and uses verified identity rather than posted email', async () => {
    const {stripe,calls} = fakeStripe(); const app = await make(stripe);
    expect((await app.inject({method:'POST',url:'/v1/checkout',payload:{email:'victim@example.com',plan:'onetime'}})).statusCode).toBe(401);
    expect((await app.inject({method:'POST',url:'/v1/checkout',headers:{cookie},payload:{email:'victim@example.com',plan:'onetime'}})).statusCode).toBe(200);
    expect(calls.customerCreated).toEqual(['buyer@example.com']);
    const flow = new URL(calls.checkout.cancel_url).searchParams.get('flow');
    const ctx = await app.inject({method:'GET',url:`/v1/checkout-context/${flow}`,headers:{cookie}});
    expect(ctx.json().plan).toBe('onetime'); await app.close();
  });

  it('POST /v1/checkout (monthly) creates a subscription session and returns its url', async () => {
    const { stripe, calls } = fakeStripe();
    const app = await make(stripe);
    const res = await app.inject({ method: 'POST', url: '/v1/checkout', headers: {cookie},
      payload: { email: 'c@example.com', plan: 'monthly' } });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ url: 'https://checkout.stripe.test/cs_1' });
    expect(calls.checkout.mode).toBe('subscription');
    expect(calls.checkout.allow_promotion_codes).toBe(true);
    expect(calls.checkout.line_items[0].price).toBe('price_m');
    expect(calls.checkout.customer).toBe('cus_1');
    expect(calls.checkout.success_url).toBe(billing.successUrl);
    await app.close();
  });

  it('rejects new yearly checkout without creating a Stripe session', async () => {
    const { stripe, calls } = fakeStripe();
    const app = await make(stripe);
    const res = await app.inject({ method: 'POST', url: '/v1/checkout', headers: {cookie},
      payload: { email: 'retired@example.com', plan: 'yearly' } });
    expect(res.statusCode).toBe(400);
    expect(calls.checkout).toBeUndefined();
    await app.close();
  });

  it('POST /v1/checkout (onetime) uses payment mode and the onetime price', async () => {
    const { stripe, calls } = fakeStripe();
    const app = await make(stripe);
    const res = await app.inject({ method: 'POST', url: '/v1/checkout', headers: {cookie},
      payload: { email: 'd@example.com', plan: 'onetime' } });
    expect(res.statusCode).toBe(200);
    expect(calls.checkout.mode).toBe('payment');
    expect(calls.checkout.allow_promotion_codes).toBe(true);
    expect(calls.checkout.line_items[0].price).toBe('price_o');
    await app.close();
  });

  it('POST /v1/checkout rejects an unknown plan with 400', async () => {
    const { stripe } = fakeStripe();
    const app = await make(stripe);
    const res = await app.inject({ method: 'POST', url: '/v1/checkout', headers: {cookie},
      payload: { email: 'e@example.com', plan: 'lifetime' } });
    expect(res.statusCode).toBe(400);
    await app.close();
  });

  it('POST /v1/portal returns a portal url for the logged-in customer', async () => {
    const { stripe, calls } = fakeStripe();
    const app = await make(stripe);
    // Create the user (+ cus_1) via checkout, then log in with that session.
    await app.inject({ method: 'POST', url: '/v1/checkout', headers: {cookie},
      payload: { email: 'f@example.com', plan: 'monthly' } });


    const res = await app.inject({ method: 'POST', url: '/v1/portal', headers: { cookie } });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ url: 'https://portal.stripe.test/bps_1' });
    expect(calls.portal.customer).toBe('cus_1');
    expect(calls.portal.return_url).toBe(billing.portalReturnUrl);
    await app.close();
  });

  it('POST /v1/portal requires a session (401)', async () => {
    const { stripe } = fakeStripe();
    const app = await make(stripe);
    const res = await app.inject({ method: 'POST', url: '/v1/portal' });
    expect(res.statusCode).toBe(401);
    await app.close();
  });

  it('POST /v1/portal 404s when the logged-in user has no Stripe customer', async () => {
    const { stripe } = fakeStripe();
    const app = await make(stripe);
    await pool.query("INSERT INTO users (id, email) VALUES ('u_nocus', 'nocus@example.com')");
    const { token } = await createSession(pool, 'u_nocus');
    const res = await app.inject({ method: 'POST', url: '/v1/portal',
      headers: { cookie: `slipreel_session=${token}` } });
    expect(res.statusCode).toBe(404);
    await app.close();
  });

  it('POST /v1/checkout rejects an oversized state value with 400', async () => {
    const { stripe } = fakeStripe();
    const app = await make(stripe);
    const res = await app.inject({ method: 'POST', url: '/v1/checkout', headers: {cookie},
      payload: { email: 'h@example.com', plan: 'monthly', state: 'x'.repeat(1000) } });
    expect(res.statusCode).toBe(400);
    await app.close();
  });

  it('checkout forwards device/state into the session metadata', async () => {
    const { stripe, calls } = fakeStripe();
    const app = await make(stripe);
    await app.inject({ method: 'POST', url: '/v1/checkout', headers: {cookie},
      payload: { email: 'g@example.com', plan: 'monthly', device: 'fp-1', device_name: 'Mac', state: 'nonce-1' } });
    expect(calls.checkout.metadata).toMatchObject({ device: 'fp-1', device_name: 'Mac', state: 'nonce-1' });
    await app.close();
  });
});
