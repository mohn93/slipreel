import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { grantComp, revokeComp } from '../src/billing/comp.js';

describe('complimentary licenses', () => {
  let pool: pg.Pool;
  beforeAll(async () => {
    pool = testPool();
    await resetDatabase(pool);
    await runMigrations(pool);
  });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM purchase_grants');
    await pool.query('DELETE FROM entitlements');
    await pool.query('DELETE FROM users');
  });

  async function tx<T>(fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const out = await fn(client);
      await client.query('COMMIT');
      return out;
    } catch (err) { await client.query('ROLLBACK'); throw err; } finally { client.release(); }
  }

  const yearOut = (d: Date | null | undefined) => (d!.getTime() - Date.now()) / 86_400_000;

  it('creates the account and an active one-time entitlement ~1 year out', async () => {
    const result = await tx(c => grantComp(c, 'friend@example.com'));
    expect(result.createdUser).toBe(true);
    expect(result.grantId).toMatch(/^comp_/);
    expect(result.entitlement?.status).toBe('active');
    expect(yearOut(result.entitlement?.updates_until)).toBeGreaterThan(364);
    const { rows } = await pool.query('SELECT stripe_customer_id FROM users WHERE email = $1', ['friend@example.com']);
    expect(rows[0].stripe_customer_id).toBeNull();
  });

  it('reuses an existing account and stacks another year on repeat grants', async () => {
    await pool.query("INSERT INTO users (id, email) VALUES ('usr_x', 'Friend@Example.com')");
    const first = await tx(c => grantComp(c, 'friend@example.com'));
    const second = await tx(c => grantComp(c, 'friend@example.com'));
    expect(first.userId).toBe('usr_x');
    expect(first.createdUser).toBe(false);
    expect(yearOut(second.entitlement?.updates_until)).toBeGreaterThan(729);
  });

  it('revokes comp grants without touching paid grants', async () => {
    await pool.query("INSERT INTO users (id, email) VALUES ('usr_p', 'paid@example.com')");
    await pool.query("INSERT INTO purchase_grants (payment_intent_id, user_id, purchased_at) VALUES ('pi_paid', 'usr_p', now())");
    await tx(c => grantComp(c, 'paid@example.com'));
    const revoked = await tx(c => revokeComp(c, 'paid@example.com'));
    expect(revoked.entitlement?.status).toBe('active');
    expect(yearOut(revoked.entitlement?.updates_until)).toBeLessThan(366);

    await tx(c => grantComp(c, 'only@example.com'));
    const gone = await tx(c => revokeComp(c, 'only@example.com'));
    expect(gone.entitlement?.status).toBe('canceled');
  });

  it('refuses users with unreconciled legacy grants', async () => {
    await pool.query("INSERT INTO users (id, email) VALUES ('usr_l', 'legacy@example.com')");
    await pool.query("INSERT INTO purchase_grants (payment_intent_id, user_id, legacy_until) VALUES ('legacy_ent_1', 'usr_l', now() + interval '1 year')");
    await expect(tx(c => grantComp(c, 'legacy@example.com'))).rejects.toThrow('unreconciled legacy');
    const { rowCount } = await pool.query("SELECT 1 FROM purchase_grants WHERE payment_intent_id LIKE 'comp_%'");
    expect(rowCount).toBe(0);
  });

  it('refuses to revoke when there is nothing to revoke', async () => {
    await expect(tx(c => revokeComp(c, 'nobody@example.com'))).rejects.toThrow('No account');
    await pool.query("INSERT INTO users (id, email) VALUES ('usr_n', 'none@example.com')");
    await expect(tx(c => revokeComp(c, 'none@example.com'))).rejects.toThrow('no active complimentary');
  });
});
