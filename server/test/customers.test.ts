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
