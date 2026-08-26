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
