import type pg from 'pg';
import { newId } from '../ids.js';
import { newSecretToken, hashToken } from './secret_token.js';

export type MagicLinkContext = {
  checkoutPlan?: string | null;
  checkoutSessionId?: string | null;
  checkoutFlow?: string | null;
  device?: string | null;
  deviceName?: string | null;
  state?: string | null;
};

export async function createMagicLink(
  pool: pg.Pool,
  userId: string,
  ctx: MagicLinkContext = {},
  ttlMinutes = 30,
): Promise<{ token: string }> {
  const { token, hash } = newSecretToken();
  const expiresAt = new Date(Date.now() + ttlMinutes * 60_000);
  await pool.query(
    `INSERT INTO magic_links (id, user_id, token_hash, expires_at, device_fingerprint, device_name, state, checkout_plan, checkout_session_id, checkout_flow)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
    [newId('mlk'), userId, hash, expiresAt, ctx.device ?? null, ctx.deviceName ?? null, ctx.state ?? null, ctx.checkoutPlan ?? null, ctx.checkoutSessionId ?? null, ctx.checkoutFlow ?? null],
  );
  return { token };
}

/** Consume a link atomically: only an unexpired, unconsumed link succeeds. */
export async function consumeMagicLink(
  pool: pg.Pool,
  token: string,
): Promise<{ userId: string; device: string | null; deviceName: string | null; state: string | null; checkoutPlan: string | null; checkoutSessionId: string | null; checkoutFlow: string | null } | null> {
  const { rows } = await pool.query<{
    checkout_plan: string | null; checkout_session_id: string | null; checkout_flow: string | null;
    user_id: string; device_fingerprint: string | null; device_name: string | null; state: string | null;
  }>(
    `UPDATE magic_links SET consumed_at = now()
     WHERE token_hash = $1 AND consumed_at IS NULL AND expires_at > now()
     RETURNING user_id, device_fingerprint, device_name, state, checkout_plan, checkout_session_id, checkout_flow`,
    [hashToken(token)],
  );
  const r = rows[0];
  return r ? { userId: r.user_id, device: r.device_fingerprint, deviceName: r.device_name, state: r.state, checkoutPlan: r.checkout_plan, checkoutSessionId: r.checkout_session_id, checkoutFlow: r.checkout_flow } : null;
}
