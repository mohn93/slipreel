import type pg from 'pg';
import { newId } from '../ids.js';
import { newSecretToken, hashToken } from './secret_token.js';

export async function createSession(
  pool: pg.Pool,
  userId: string,
  ttlHours = 720,
): Promise<{ token: string; expiresAt: Date }> {
  const { token, hash } = newSecretToken();
  const expiresAt = new Date(Date.now() + ttlHours * 3600_000);
  await pool.query(
    'INSERT INTO sessions (id, user_id, token_hash, expires_at) VALUES ($1, $2, $3, $4)',
    [newId('ses'), userId, hash, expiresAt],
  );
  return { token, expiresAt };
}

export async function resolveSession(
  pool: pg.Pool,
  token: string,
): Promise<{ userId: string } | null> {
  const { rows } = await pool.query<{ user_id: string }>(
    'SELECT user_id FROM sessions WHERE token_hash = $1 AND expires_at > now()',
    [hashToken(token)],
  );
  return rows[0] ? { userId: rows[0].user_id } : null;
}

export async function deleteSession(pool: pg.Pool, token: string): Promise<void> {
  await pool.query('DELETE FROM sessions WHERE token_hash = $1', [hashToken(token)]);
}
