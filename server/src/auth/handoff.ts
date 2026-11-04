import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';
import type pg from 'pg';

/**
 * Cross-device sign-in handoff. When a browser finishes an app-initiated
 * sign-in, the result (device credentials or an error) is parked here keyed by
 * the app's secret `state` nonce. The Mac app polls with that nonce and claims
 * it once. Only hashes/derived keys of the nonce are stored, so a database
 * reader cannot recover the credentials.
 */
export type HandoffResult =
  | { token: string; refresh_token: string; device_id: string }
  | { error: 'seat_limit' | 'activation_failed' };

const TTL_MINUTES = 15;

function handoffId(state: string): string {
  return createHash('sha256').update('slipreel-handoff-id:' + state).digest('hex');
}

function handoffKey(state: string): Buffer {
  return createHash('sha256').update('slipreel-handoff-key:' + state).digest();
}

function seal(state: string, value: HandoffResult): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', handoffKey(state), iv);
  const body = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
  return [iv, cipher.getAuthTag(), body].map((b) => b.toString('base64url')).join('.');
}

function open(state: string, sealed: string): HandoffResult | null {
  try {
    const [iv, tag, body] = sealed.split('.').map((p) => Buffer.from(p, 'base64url'));
    if (!iv || !tag || !body) return null;
    const decipher = createDecipheriv('aes-256-gcm', handoffKey(state), iv);
    decipher.setAuthTag(tag);
    const text = Buffer.concat([decipher.update(body), decipher.final()]).toString('utf8');
    return JSON.parse(text) as HandoffResult;
  } catch {
    return null;
  }
}

/** Park (or replace) the result for this state; the newest approval wins. */
export async function storeHandoff(
  pool: pg.Pool, state: string, fingerprint: string, value: HandoffResult,
): Promise<void> {
  await pool.query(
    `INSERT INTO auth_handoffs (id, fingerprint, payload, expires_at)
     VALUES ($1, $2, $3, now() + ($4 || ' minutes')::interval)
     ON CONFLICT (id) DO UPDATE SET fingerprint = EXCLUDED.fingerprint,
       payload = EXCLUDED.payload, expires_at = EXCLUDED.expires_at`,
    [handoffId(state), fingerprint, seal(state, value), String(TTL_MINUTES)],
  );
}

/**
 * Claim the result once. Returns null while nothing is waiting (or the
 * fingerprint does not match the device that started sign-in).
 */
export async function claimHandoff(
  pool: pg.Pool, state: string, fingerprint: string,
): Promise<HandoffResult | null> {
  await pool.query('DELETE FROM auth_handoffs WHERE expires_at <= now()');
  const { rows } = await pool.query<{ payload: string }>(
    'DELETE FROM auth_handoffs WHERE id = $1 AND fingerprint = $2 AND expires_at > now() RETURNING payload',
    [handoffId(state), fingerprint],
  );
  const row = rows[0];
  return row ? open(state, row.payload) : null;
}
