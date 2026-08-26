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
