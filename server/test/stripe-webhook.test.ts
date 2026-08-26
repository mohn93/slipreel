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
