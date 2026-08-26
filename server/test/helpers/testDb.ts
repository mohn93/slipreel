import pg from 'pg';

export function testPool(): pg.Pool {
  const url = process.env.TEST_DATABASE_URL;
  if (!url) {
    throw new Error(
      'TEST_DATABASE_URL is not set. Copy server/.env.example to server/.env ' +
        'and run `npm run db:up` (see server/README.md).',
    );
  }
  return new pg.Pool({ connectionString: url, max: 4 });
}

/** Drop and recreate the public schema so a test file starts from empty. */
export async function resetDatabase(pool: pg.Pool): Promise<void> {
  await pool.query('DROP SCHEMA IF EXISTS public CASCADE');
  await pool.query('CREATE SCHEMA public');
}
