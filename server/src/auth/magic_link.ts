import type pg from 'pg';
import { newId } from '../ids.js';
import { newSecretToken, hashToken } from './secret_token.js';

export async function createMagicLink(
  pool: pg.Pool,
  userId: string,
  ttlMinutes = 15,
): Promise<{ token: string }> {
  const { token, hash } = newSecretToken();
  const expiresAt = new Date(Date.now() + ttlMinutes * 60_000);
  await pool.query(
    'INSERT INTO magic_links (id, user_id, token_hash, expires_at) VALUES ($1, $2, $3, $4)',
    [newId('mlk'), userId, hash, expiresAt],
  );
  return { token };
}

/** Consume a link atomically: only an unexpired, unconsumed link succeeds. */
export async function consumeMagicLink(
  pool: pg.Pool,
  token: string,
): Promise<{ userId: string } | null> {
  const { rows } = await pool.query<{ user_id: string }>(
    `UPDATE magic_links SET consumed_at = now()
     WHERE token_hash = $1 AND consumed_at IS NULL AND expires_at > now()
     RETURNING user_id`,
    [hashToken(token)],
  );
  return rows[0] ? { userId: rows[0].user_id } : null;
}
