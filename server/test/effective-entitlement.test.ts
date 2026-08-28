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

  it('a canceled one-time row (no subscription) does not grant export', async () => {
    await seedUser(pool, 'u_ot_canceled');
    await pool.query(
      `INSERT INTO entitlements (id, user_id, plan, status, updates_until)
       VALUES ($1, $2, 'onetime', 'canceled', now() + interval '200 days')`,
      ['ent_u_ot_canceled_o', 'u_ot_canceled']);
    const e = await resolveEffectiveEntitlement(pool, 'u_ot_canceled');
    expect(e).toEqual({ plan: 'free', status: 'none', updatesUntil: null, export: false });
  });
});
