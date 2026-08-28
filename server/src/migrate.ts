import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import type pg from 'pg';

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'migrations');

const MIGRATION_FILE = /^\d{4}_.+\.sql$/;

export async function runMigrations(
  pool: pg.Pool,
  dir: string = MIGRATIONS_DIR,
): Promise<string[]> {
  await pool.query(
    `CREATE TABLE IF NOT EXISTS schema_migrations (
       filename    text PRIMARY KEY,
       applied_at  timestamptz NOT NULL DEFAULT now()
     )`,
  );

  const files = (await readdir(dir))
    .filter((f) => MIGRATION_FILE.test(f))
    .sort();

  const { rows } = await pool.query<{ filename: string }>(
    'SELECT filename FROM schema_migrations',
  );
  const done = new Set(rows.map((r) => r.filename));

  const applied: string[] = [];
  for (const file of files) {
    if (done.has(file)) continue;
    const sql = await readFile(join(dir, file), 'utf8');
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query(sql);
      await client.query('INSERT INTO schema_migrations (filename) VALUES ($1)', [file]);
      await client.query('COMMIT');
      applied.push(file);
    } catch (err) {
      await client.query('ROLLBACK');
      throw new Error(`Migration ${file} failed: ${(err as Error).message}`);
    } finally {
      client.release();
    }
  }
  return applied;
}
