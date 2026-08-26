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

  it('checkout forwards device/state into the session metadata', async () => {
    const { stripe, calls } = fakeStripe();
    const app = await make(stripe);
    await app.inject({ method: 'POST', url: '/v1/checkout',
      payload: { email: 'g@example.com', plan: 'yearly', device: 'fp-1', device_name: 'Mac', state: 'nonce-1' } });
    expect(calls.checkout.metadata).toEqual({ device: 'fp-1', device_name: 'Mac', state: 'nonce-1' });
    await app.close();
  });
});
