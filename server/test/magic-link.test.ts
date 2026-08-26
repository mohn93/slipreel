import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';

describe('magic link', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM magic_links'); await pool.query('DELETE FROM sessions');
    await pool.query('DELETE FROM users');
    await pool.query("INSERT INTO users (id, email) VALUES ('u_m','m@e.com')");
  });

  it('issues a debug token for a known email and verifies it into a session', async () => {
    const { app } = await makeLicensingApp(pool);
    const req = await app.inject({ method: 'POST', url: '/v1/auth/magic-link', payload: { email: 'm@e.com' } });
    expect(req.statusCode).toBe(200);
    const token = req.json().debug_token as string;
    expect(token).toBeTruthy();

    const ver = await app.inject({ method: 'POST', url: '/v1/auth/magic-link/verify', payload: { token } });
    expect(ver.statusCode).toBe(200);
    expect(ver.json().user.id).toBe('u_m');
    expect(String(ver.headers['set-cookie'])).toContain('slipreel_session=');
    await app.close();
  });

  it('does not leak existence for an unknown email (200, no token)', async () => {
    const { app } = await makeLicensingApp(pool);
    const req = await app.inject({ method: 'POST', url: '/v1/auth/magic-link', payload: { email: 'nobody@e.com' } });
    expect(req.statusCode).toBe(200);
    expect(req.json().debug_token).toBeUndefined();
    await app.close();
  });

  it('a link is single-use (second verify 401s)', async () => {
    const { app } = await makeLicensingApp(pool);
    const token = (await app.inject({ method: 'POST', url: '/v1/auth/magic-link', payload: { email: 'm@e.com' } })).json().debug_token;
    await app.inject({ method: 'POST', url: '/v1/auth/magic-link/verify', payload: { token } });
    const again = await app.inject({ method: 'POST', url: '/v1/auth/magic-link/verify', payload: { token } });
    expect(again.statusCode).toBe(401);
    await app.close();
  });

  it('rejects a bogus token', async () => {
    const { app } = await makeLicensingApp(pool);
    const res = await app.inject({ method: 'POST', url: '/v1/auth/magic-link/verify', payload: { token: 'bogus' } });
    expect(res.statusCode).toBe(401);
    await app.close();
  });
});
