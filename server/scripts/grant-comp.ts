/** Give or revoke a complimentary license by email. Dry run unless --apply. */
import pg from 'pg';
import { grantComp, revokeComp } from '../src/billing/comp.js';

const args = process.argv.slice(2);
const email = args[args.indexOf('--email') + 1]?.trim().toLowerCase();
if (!args.includes('--email') || !email || email.startsWith('--') || !email.includes('@')) {
  throw new Error('Usage: npm run comp:grant -- --email someone@example.com [--revoke] [--apply]');
}
if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required');
const apply = args.includes('--apply');
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
try {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = args.includes('--revoke') ? await revokeComp(client, email) : await grantComp(client, email);
    console.log(JSON.stringify({ email, action: args.includes('--revoke') ? 'revoke' : 'grant', mode: apply ? 'apply' : 'dry_run', ...result }, null, 2));
    await client.query(apply ? 'COMMIT' : 'ROLLBACK');
    if (!apply) console.log('Dry run only. Re-run with --apply to save.');
  } catch (err) { await client.query('ROLLBACK'); throw err; } finally { client.release(); }
} finally { await pool.end(); }
