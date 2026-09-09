import {createSession} from '../src/auth/sessions.js';
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';

async function login(app: any): Promise<string> {
  const user = (await app.pool.query('SELECT id FROM users ORDER BY id LIMIT 1')).rows[0];
  const {token} = await createSession(app.pool, user.id);
  return `slipreel_session=${token}`;
}

describe('entitlement route', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM entitlements'); await pool.query('DELETE FROM sessions');
    await pool.query('DELETE FROM consumed_checkout_sessions'); await pool.query('DELETE FROM users');
    await pool.query("INSERT INTO users (id, email, stripe_customer_id) VALUES ('u1','u1@e.com','cus_1')");
  });

  it('requires auth (401)', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const res = await app.inject({ method: 'GET', url: '/v1/entitlement' });
    expect(res.statusCode).toBe(401);
    await app.close();
  });

  it('returns free for a user with no entitlements', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const cookie = await login(app);
    const res = await app.inject({ method: 'GET', url: '/v1/entitlement', headers: { cookie } });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ plan: 'free', status: 'none', updatesUntil: null, export: false });
    await app.close();
  });

  it('reflects an active subscription for the logged-in user', async () => {
    await pool.query(
      `INSERT INTO entitlements (id, user_id, plan, status, stripe_subscription_id, current_period_end)
       VALUES ('ent_u1_s','u1','subscription','active','sub_u1', now() + interval '30 days')`);
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const cookie = await login(app);
    const res = await app.inject({ method: 'GET', url: '/v1/entitlement', headers: { cookie } });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.plan).toBe('subscription');
    expect(body.status).toBe('active');
    expect(body.export).toBe(true);
    await app.close();
  });

  it('reflects a one-time license with an updates ceiling', async () => {
    await pool.query(
      `INSERT INTO entitlements (id, user_id, plan, status, updates_until)
       VALUES ('ent_u1_o','u1','onetime','active', now() + interval '200 days')`);
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const cookie = await login(app);
    const res = await app.inject({ method: 'GET', url: '/v1/entitlement', headers: { cookie } });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.plan).toBe('onetime');
    expect(body.status).toBe('active');
    expect(typeof body.updatesUntil).toBe('string');
    await app.close();
  });
});
