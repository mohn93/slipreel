import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type pg from 'pg';
import { testPool, resetDatabase } from './helpers/testDb.js';
import { runMigrations } from '../src/migrate.js';

describe('runMigrations', () => {
  let pool: pg.Pool;

  beforeAll(async () => {
    pool = testPool();
    await resetDatabase(pool);
  });

  afterAll(async () => {
    await pool.end();
  });

  it('applies the initial migration and creates the expected tables', async () => {
    const applied = await runMigrations(pool);
    expect(applied).toContain('0001_init.sql');

    const { rows } = await pool.query<{ table_name: string }>(
      `SELECT table_name FROM information_schema.tables
       WHERE table_schema = 'public' ORDER BY table_name`,
    );
    const names = rows.map((r) => r.table_name);
    expect(names).toEqual(
      expect.arrayContaining([
        'users',
        'entitlements',
        'devices',
        'processed_stripe_events',
        'schema_migrations',
      ]),
    );
  });

  it('is idempotent — a second run applies nothing', async () => {
    const applied = await runMigrations(pool);
    expect(applied).toEqual([]);
  });
});
