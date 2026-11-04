import {createSession} from '../src/auth/sessions.js';
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';

// Log a user in via session-from-checkout and return the session cookie.
async function login(app: any, customer: string): Promise<string> {
  const user = (await app.pool.query('SELECT id FROM users ORDER BY id LIMIT 1')).rows[0];
  const {token} = await createSession(app.pool, user.id);
  return `slipreel_session=${token}`;
}

describe('token routes', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM auth_handoffs'); await pool.query('DELETE FROM magic_links');
    await pool.query('DELETE FROM devices'); await pool.query('DELETE FROM sessions');
    await pool.query('DELETE FROM entitlements'); await pool.query('DELETE FROM users');
    await pool.query('DELETE FROM consumed_checkout_sessions');
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
  describe('cross-device handoff', () => {
    const state = 'h1.' + 'a'.repeat(43);
    const claim = (app: any, body: Record<string, string>) =>
      app.inject({ method: 'POST', url: '/v1/auth/handoff/claim', payload: body });
    // Request + verify a magic link the way the login page does, returning the
    // session cookie of whoever clicked it.
    async function approve(app: any, email: string, ctx: Record<string, string>): Promise<string> {
      const token = (await app.inject({ method: 'POST', url: '/v1/auth/magic-link',
        payload: { email, ...ctx } })).json().debug_token;
      const ver = await app.inject({ method: 'POST', url: '/v1/auth/magic-link/verify', payload: { token } });
      expect(ver.statusCode).toBe(200);
      const raw = ver.headers['set-cookie'];
      const cookie = (Array.isArray(raw) ? raw[0] : raw)!.split(';')[0]!;
      return cookie;
    }
    const mint = (app: any, cookie: string, payload: Record<string, string>) =>
      app.inject({ method: 'POST', url: '/v1/token', headers: { cookie }, payload });

    it('is pending (204) until approved, then returns the credentials once', async () => {
      const { app, signer } = await makeLicensingApp(pool);
      expect((await claim(app, { state, fingerprint: 'fp-mac' })).statusCode).toBe(204);
      const cookie = await approve(app, 'u1@e.com', { device: 'fp-mac', state });
      const minted = await mint(app, cookie, { fingerprint: 'fp-mac', device_name: 'Mac', state });
      expect(minted.statusCode).toBe(200);
      const first = await claim(app, { state, fingerprint: 'fp-mac' });
      expect(first.statusCode).toBe(200);
      expect(first.json()).toEqual({ ...minted.json(), email: 'u1@e.com' });
      expect((await signer.verify(first.json().token)).device_id).toBe(minted.json().device_id);
      expect((await claim(app, { state, fingerprint: 'fp-mac' })).statusCode).toBe(204);
      await app.close();
    });

    it('a session cannot plant credentials for a state it never verified', async () => {
      const { app } = await makeLicensingApp(pool);
      await pool.query("INSERT INTO users (id, email) VALUES ('u2','attacker@e.com')");
      const attacker = await approve(app, 'attacker@e.com', {});
      const res = await mint(app, attacker, { fingerprint: 'fp-mac', state });
      expect(res.statusCode).toBe(200); // their own browser activation still works
      expect((await claim(app, { state, fingerprint: 'fp-mac' })).statusCode).toBe(204);
      await app.close();
    });

    it('another user cannot fill an intent opened by the link owner', async () => {
      const { app } = await makeLicensingApp(pool);
      await approve(app, 'u1@e.com', { device: 'fp-mac', state });
      await pool.query("INSERT INTO users (id, email) VALUES ('u2','attacker@e.com')");
      const attacker = await approve(app, 'attacker@e.com', {});
      await mint(app, attacker, { fingerprint: 'fp-mac', state });
      expect((await claim(app, { state, fingerprint: 'fp-mac' })).statusCode).toBe(204);
      await app.close();
    });

    it('a second approval does not rotate the claimed credentials', async () => {
      const { app } = await makeLicensingApp(pool);
      const cookie = await approve(app, 'u1@e.com', { device: 'fp-mac', state });
      await mint(app, cookie, { fingerprint: 'fp-mac', state });
      const claimed = (await claim(app, { state, fingerprint: 'fp-mac' })).json();
      const again = await mint(app, cookie, { fingerprint: 'fp-mac', state });
      expect(again.statusCode).toBe(409);
      expect(again.json().error).toBe('already_approved');
      const refresh = await app.inject({ method: 'POST', url: '/v1/token/refresh',
        payload: { refresh_token: claimed.refresh_token, device_id: claimed.device_id } });
      expect(refresh.statusCode).toBe(200);
      await app.close();
    });

    it('stores nothing locatable or readable from the state alone', async () => {
      const { app } = await makeLicensingApp(pool);
      const cookie = await approve(app, 'u1@e.com', { device: 'fp-mac', state });
      const minted = (await mint(app, cookie, { fingerprint: 'fp-mac', state })).json();
      const { createHash } = await import('node:crypto');
      const { rows } = await pool.query('SELECT id, payload FROM auth_handoffs');
      expect(rows).toHaveLength(1);
      expect(rows[0].id).not.toBe(createHash('sha256').update(state).digest('hex'));
      expect(rows[0].payload).not.toContain(minted.refresh_token);
      await app.close();
    });

    it('rejects a claim with the wrong state or fingerprint', async () => {
      const { app } = await makeLicensingApp(pool);
      const cookie = await approve(app, 'u1@e.com', { device: 'fp-mac', state });
      await mint(app, cookie, { fingerprint: 'fp-mac', state });
      expect((await claim(app, { state: 'h1.' + 'b'.repeat(43), fingerprint: 'fp-mac' })).statusCode).toBe(204);
      expect((await claim(app, { state, fingerprint: 'fp-other' })).statusCode).toBe(204);
      expect((await claim(app, { state, fingerprint: 'fp-mac' })).statusCode).toBe(200);
      await app.close();
    });

    it('hands a seat-limit failure to the app as 409', async () => {
      const { app } = await makeLicensingApp(pool);
      const cookie = await approve(app, 'u1@e.com', { device: 'fp-3', state });
      for (const fp of ['fp-1', 'fp-2']) await mint(app, cookie, { fingerprint: fp });
      const third = await mint(app, cookie, { fingerprint: 'fp-3', state });
      expect(third.statusCode).toBe(409);
      const res = await claim(app, { state, fingerprint: 'fp-3' });
      expect(res.statusCode).toBe(409);
      expect(res.json().error).toBe('seat_limit');
      await app.close();
    });

    it('legacy (non h1.) states never open an intent', async () => {
      const { app } = await makeLicensingApp(pool);
      const legacy = 'legacy-nonce-0123456789';
      const cookie = await approve(app, 'u1@e.com', { device: 'fp-mac', state: legacy });
      await mint(app, cookie, { fingerprint: 'fp-mac', state: legacy });
      expect((await pool.query('SELECT 1 FROM auth_handoffs')).rowCount).toBe(0);
      await app.close();
    });

    it('expired handoffs are not claimable', async () => {
      const { app } = await makeLicensingApp(pool);
      const cookie = await approve(app, 'u1@e.com', { device: 'fp-mac', state });
      await mint(app, cookie, { fingerprint: 'fp-mac', state });
      await pool.query("UPDATE auth_handoffs SET expires_at = now() - interval '1 second'");
      expect((await claim(app, { state, fingerprint: 'fp-mac' })).statusCode).toBe(204);
      await app.close();
    });

    it('a failure to park does not fail the browser activation', async () => {
      const { app } = await makeLicensingApp(pool);
      const cookie = await approve(app, 'u1@e.com', { device: 'fp-mac', state });
      await pool.query('ALTER TABLE auth_handoffs ADD CONSTRAINT no_fill CHECK (payload IS NULL)');
      try {
        const res = await mint(app, cookie, { fingerprint: 'fp-mac', state });
        expect(res.statusCode).toBe(200);
      } finally {
        await pool.query('ALTER TABLE auth_handoffs DROP CONSTRAINT no_fill');
      }
      await app.close();
    });
  });
});
