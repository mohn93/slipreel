import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';

describe('entitlement public-key route', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });

  it('serves the signer public key as text/plain', async () => {
    const { app, signer } = await makeLicensingApp(pool);
    const res = await app.inject({ method: 'GET', url: '/v1/entitlement/public-key' });
    expect(res.statusCode).toBe(200);
    expect(res.headers['content-type']).toContain('text/plain');
    expect(res.body).toBe(signer.publicKeyPem);
    await app.close();
  });
});
