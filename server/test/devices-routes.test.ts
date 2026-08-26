import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';

async function login(app: any): Promise<string> {
  const res = await app.inject({ method: 'POST', url: '/v1/auth/session-from-checkout',
    payload: { checkout_session_id: 'cs' } });
  return String(res.headers['set-cookie']).split(';')[0];
}

describe('device routes', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM devices'); await pool.query('DELETE FROM sessions'); await pool.query('DELETE FROM users');
    await pool.query("INSERT INTO users (id, email, stripe_customer_id) VALUES ('u1','u1@e.com','cus_1')");
    await pool.query("INSERT INTO users (id, email, stripe_customer_id) VALUES ('u2','u2@e.com','cus_2')");
  });

  it('lists the user devices and deletes one (freeing a seat)', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const cookie = await login(app);
    await app.inject({ method: 'POST', url: '/v1/token', headers: { cookie }, payload: { fingerprint: 'fp-1', device_name: 'A' } });
    await app.inject({ method: 'POST', url: '/v1/token', headers: { cookie }, payload: { fingerprint: 'fp-2', device_name: 'B' } });

    const list = await app.inject({ method: 'GET', url: '/v1/devices', headers: { cookie } });
    expect(list.statusCode).toBe(200);
    const devices = list.json().devices as Array<{ id: string }>;
    expect(devices).toHaveLength(2);

    const del = await app.inject({ method: 'DELETE', url: `/v1/devices/${devices[0].id}`, headers: { cookie } });
    expect(del.statusCode).toBe(200);
    const after = await app.inject({ method: 'GET', url: '/v1/devices', headers: { cookie } });
    expect(after.json().devices).toHaveLength(1);
    await app.close();
  });

  it('requires auth (401)', async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    const res = await app.inject({ method: 'GET', url: '/v1/devices' });
    expect(res.statusCode).toBe(401);
    await app.close();
  });

  it("404s when deleting another user's device", async () => {
    const { app } = await makeLicensingApp(pool, { session: { status: 'complete', customer: 'cus_1' } });
    // seed a device owned by u2 directly
    await pool.query("INSERT INTO devices (id, user_id, fingerprint, refresh_token_hash) VALUES ('dev_u2','u2','fpx','h')");
    const cookie = await login(app);
    const del = await app.inject({ method: 'DELETE', url: '/v1/devices/dev_u2', headers: { cookie } });
    expect(del.statusCode).toBe(404);
    await app.close();
  });
});
