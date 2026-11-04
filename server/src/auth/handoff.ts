import { createCipheriv, createDecipheriv, createHmac, randomBytes } from 'node:crypto';
import type pg from 'pg';

/**
 * Cross-device sign-in handoff. Lets the Mac app receive a sign-in approved in
 * a browser on any device (often a phone that cannot open slipreel://).
 *
 * Lifecycle of one row, keyed by the app's secret `state` nonce:
 *   1. openIntent: a magic link or checkout that carried this state was
 *      verified. Binds the row to that user and the app's fingerprint.
 *   2. fillIntent: /v1/token minted credentials for exactly that user and
 *      fingerprint. Only an unfilled intent can be filled, so a session cannot
 *      plant its account's credentials for a state it did not verify.
 *   3. claimHandoff: the app polls with state + fingerprint and receives the
 *      result once.
 *
 * The id and the payload key are HMACs of the state under a server secret, so
 * a database reader cannot locate or decrypt a row even though the plain state
 * also appears in magic_links / Stripe metadata.
 */
export type HandoffResult =
  | { token: string; refresh_token: string; device_id: string; email: string | null }
  | { error: 'seat_limit' | 'activation_failed' };

export type HandoffSecret = Buffer;

export const HANDOFF_PREFIX = 'h1.';
export function supportsHandoff(state: string | null | undefined): state is string {
  return typeof state === 'string' && state.startsWith(HANDOFF_PREFIX);
}

/** Server secret for handoff ids/keys. Falls back to a per-process random key. */
export function handoffSecretFrom(material: string | undefined): HandoffSecret {
  return material ? createHmac('sha256', 'slipreel-handoff').update(material).digest() : randomBytes(32);
}

const INTENT_MINUTES = 35; // magic-link lifetime (30) plus margin
const RESULT_MINUTES = 15;

function handoffId(secret: HandoffSecret, state: string): string {
  return createHmac('sha256', secret).update('id:' + state).digest('hex');
}

function handoffKey(secret: HandoffSecret, state: string): Buffer {
  return createHmac('sha256', secret).update('key:' + state).digest();
}

function seal(key: Buffer, value: HandoffResult): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const body = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
  return [iv, cipher.getAuthTag(), body].map((b) => b.toString('base64url')).join('.');
}

function open(key: Buffer, sealed: string): HandoffResult | null {
  try {
    const [iv, tag, body] = sealed.split('.').map((p) => Buffer.from(p, 'base64url'));
    if (!iv || !tag || !body) return null;
    const decipher = createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAuthTag(tag);
    return JSON.parse(Buffer.concat([decipher.update(body), decipher.final()]).toString('utf8')) as HandoffResult;
  } catch {
    return null;
  }
}

/**
 * Record that `userId` verified a link/checkout carrying `state` for the app
 * identified by `fingerprint`. A later verify for the same state replaces an
 * unfilled intent (the newest email wins); a filled one is left alone.
 */
export async function openIntent(
  pool: pg.Pool, secret: HandoffSecret, state: string, userId: string, fingerprint: string,
): Promise<void> {
  await pool.query('DELETE FROM auth_handoffs WHERE expires_at <= now()');
  await pool.query(
    `INSERT INTO auth_handoffs (id, user_id, fingerprint, expires_at)
     VALUES ($1, $2, $3, now() + ($4 || ' minutes')::interval)
     ON CONFLICT (id) DO UPDATE SET user_id = EXCLUDED.user_id, fingerprint = EXCLUDED.fingerprint,
       expires_at = EXCLUDED.expires_at
     WHERE auth_handoffs.payload IS NULL AND auth_handoffs.claimed_at IS NULL`,
    [handoffId(secret, state), userId, fingerprint, String(INTENT_MINUTES)],
  );
}

export type IntentStatus = 'open' | 'used' | 'none';

/** Whether /v1/token may fill this state for this user + fingerprint. */
export async function intentStatus(
  pool: pg.Pool, secret: HandoffSecret, state: string, userId: string, fingerprint: string,
): Promise<IntentStatus> {
  const { rows } = await pool.query<{ used: boolean }>(
    `SELECT (payload IS NOT NULL OR claimed_at IS NOT NULL) AS used FROM auth_handoffs
     WHERE id = $1 AND user_id = $2 AND fingerprint = $3 AND expires_at > now()`,
    [handoffId(secret, state), userId, fingerprint],
  );
  const row = rows[0];
  if (!row) return 'none';
  return row.used ? 'used' : 'open';
}

/** Fill an open intent. Returns false when there is no matching open intent. */
export async function fillIntent(
  pool: pg.Pool, secret: HandoffSecret, state: string, userId: string, fingerprint: string, value: HandoffResult,
): Promise<boolean> {
  const { rowCount } = await pool.query(
    `UPDATE auth_handoffs SET payload = $4, expires_at = now() + ($5 || ' minutes')::interval
     WHERE id = $1 AND user_id = $2 AND fingerprint = $3 AND payload IS NULL AND claimed_at IS NULL
       AND expires_at > now()`,
    [handoffId(secret, state), userId, fingerprint, seal(handoffKey(secret, state), value), String(RESULT_MINUTES)],
  );
  return (rowCount ?? 0) > 0;
}

/**
 * Claim a filled result once. Returns null while nothing is waiting, or when
 * the fingerprint does not match the device that started sign-in.
 */
export async function claimHandoff(
  pool: pg.Pool, secret: HandoffSecret, state: string, fingerprint: string,
): Promise<HandoffResult | null> {
  const { rows } = await pool.query<{ payload: string }>(
    `UPDATE auth_handoffs h SET claimed_at = now(), payload = NULL
     FROM (SELECT id, payload FROM auth_handoffs
           WHERE id = $1 AND fingerprint = $2 AND payload IS NOT NULL AND claimed_at IS NULL AND expires_at > now()
           FOR UPDATE) old
     WHERE h.id = old.id
     RETURNING old.payload`,
    [handoffId(secret, state), fingerprint],
  );
  const row = rows[0];
  return row ? open(handoffKey(secret, state), row.payload) : null;
}
