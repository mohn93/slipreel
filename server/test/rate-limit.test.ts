import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';
import { makeLicensingApp } from './helpers/licensing.js';

describe('rate limiting', () => {
  let pool: pg.Pool;
  beforeAll(async () => { pool = testPool(); await resetDatabase(pool); await runMigrations(pool); });
  afterAll(async () => { await pool.end(); });

  it('429s the magic-link request past 5/min from one IP', async () => {
    const { app } = await makeLicensingApp(pool);
    const codes: number[] = [];
    for (let i = 0; i < 6; i++) {
      const res = await app.inject({
        method: 'POST', url: '/v1/auth/magic-link',
        remoteAddress: '203.0.113.7',
        payload: { email: `x${i}@e.com` },
      });
      codes.push(res.statusCode);
    }
    expect(codes.slice(0, 5).every((c) => c === 200)).toBe(true);
    expect(codes[5]).toBe(429);
    await app.close();
  });
});
