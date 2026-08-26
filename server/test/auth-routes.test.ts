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
      session: { status: 'complete', customer: 'cus_c', created: Math.floor(Date.now() / 1000) },
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

  it('rejects a stale checkout session (created over 30 minutes ago) with 400', async () => {
    const { app } = await makeLicensingApp(pool, {
      session: { status: 'complete', customer: 'cus_c', created: Math.floor(Date.now() / 1000) - 3600 },
    });
    const res = await app.inject({ method: 'POST', url: '/v1/auth/session-from-checkout',
      payload: { checkout_session_id: 'cs_stale' } });
    expect(res.statusCode).toBe(400);
    await app.close();
  });

  it('logout requires a session (401 without cookie) and clears it with one', async () => {
    const { app } = await makeLicensingApp(pool, {
      session: { status: 'complete', customer: 'cus_c', created: Math.floor(Date.now() / 1000) },
    });
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
