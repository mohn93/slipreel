import { loadConfig } from './config.js';
import { createPool } from './db.js';
import { runMigrations } from './migrate.js';

const pool = createPool(loadConfig());
try {
  const applied = await runMigrations(pool);
  console.log(applied.length ? `Applied: ${applied.join(', ')}` : 'Already up to date.');
} catch (err) {
  console.error((err as Error).message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
