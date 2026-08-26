import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { newSecretToken, hashToken } from '../src/auth/secret_token.js';
import { createSession, resolveSession, deleteSession } from '../src/auth/sessions.js';

describe('secret_token', () => {
  it('produces a token and its sha256 hash, unique per call', () => {
    const a = newSecretToken();
    const b = newSecretToken();
    expect(a.token).not.toBe(b.token);
    expect(a.hash).toBe(hashToken(a.token));
    expect(a.hash).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe('sessions', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });
  beforeEach(async () => {
    await pool.query('DELETE FROM sessions'); await pool.query('DELETE FROM users');
    await pool.query("INSERT INTO users (id, email) VALUES ('u1', 'u1@e.com')");
  });

  it('creates a session that resolves to the user', async () => {
    const { token } = await createSession(pool, 'u1');
    expect(await resolveSession(pool, token)).toEqual({ userId: 'u1' });
  });

  it('returns null for an unknown token', async () => {
    expect(await resolveSession(pool, 'nope')).toBeNull();
  });

  it('returns null for an expired session', async () => {
    const { token } = await createSession(pool, 'u1', 0); // expires now
    // force-expire in case of clock granularity
    await pool.query("UPDATE sessions SET expires_at = now() - interval '1 minute'");
    expect(await resolveSession(pool, token)).toBeNull();
  });

  it('delete removes the session', async () => {
    const { token } = await createSession(pool, 'u1');
    await deleteSession(pool, token);
    expect(await resolveSession(pool, token)).toBeNull();
  });
});
