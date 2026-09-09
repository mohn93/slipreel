import type pg from 'pg';
import { newId } from '../ids.js';
import { newSecretToken, hashToken } from './secret_token.js';

export const SEAT_LIMIT = 2;

export type DeviceInfo = { id: string; name: string | null; lastSeenAt: string | null };

/**
 * Register (or re-activate) the device identified by `fingerprint` for a user.
 * A known fingerprint rotates its refresh token (no new seat). A new
 * fingerprint consumes a seat; over `seatLimit` returns a seat_limit result
 * with the current device list so the client can prompt to deactivate one.
 */
export async function registerDevice(
  pool: pg.Pool,
  userId: string,
  fingerprint: string,
  name: string | null,
  seatLimit: number,
  location: string | null = null,
): Promise<
  | { ok: true; deviceId: string; refreshToken: string }
  | { ok: false; reason: 'seat_limit'; devices: DeviceInfo[] }
> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // Serialize seat allocation and refresh rotation for this account.
    await client.query('SELECT id FROM users WHERE id = $1 FOR UPDATE', [userId]);
  const { token, hash } = newSecretToken();

  const existing = await client.query<{ id: string }>(
    'SELECT id FROM devices WHERE user_id = $1 AND fingerprint = $2',
    [userId, fingerprint],
  );
  if (existing.rows[0]) {
    const id = existing.rows[0].id;
    await client.query(
      'UPDATE devices SET refresh_token_hash = $1, name = COALESCE($2, name), location = COALESCE($3, location), last_seen_at = now() WHERE id = $4',
      [hash, name, location, id],
    );
    await client.query('COMMIT');
    return { ok: true, deviceId: id, refreshToken: token };
  }

  const count = await client.query<{ n: string }>(
    'SELECT count(*)::int AS n FROM devices WHERE user_id = $1',
    [userId],
  );
  if (Number(count.rows[0]!.n) >= seatLimit) {
    const list = await client.query<{ id: string; name: string | null; last_seen_at: Date | null }>(
      'SELECT id, name, last_seen_at FROM devices WHERE user_id = $1 ORDER BY created_at',
      [userId],
    );
    await client.query('COMMIT');
    return {
      ok: false,
      reason: 'seat_limit',
      devices: list.rows.map((r) => ({ id: r.id, name: r.name, lastSeenAt: r.last_seen_at?.toISOString() ?? null })),
    };
  }

  const id = newId('dev');
  await client.query(
    'INSERT INTO devices (id, user_id, fingerprint, name, location, refresh_token_hash, last_seen_at) VALUES ($1,$2,$3,$4,$5,$6,now())',
    [id, userId, fingerprint, name, location, hash],
  );
  await client.query('COMMIT');
    return { ok: true, deviceId: id, refreshToken: token };
  } catch (err) { await client.query('ROLLBACK'); throw err; }
  finally { client.release(); }
}

/** Validate a device refresh token; on success bump last_seen (+ location) and return the owner. */
export async function refreshDevice(
  pool: pg.Pool,
  deviceId: string,
  refreshToken: string,
  location: string | null = null,
): Promise<{ userId: string } | null> {
  const { rows } = await pool.query<{ user_id: string }>(
    'UPDATE devices SET last_seen_at = now(), location = COALESCE($3, location) WHERE id = $1 AND refresh_token_hash = $2 RETURNING user_id',
    [deviceId, hashToken(refreshToken), location],
  );
  return rows[0] ? { userId: rows[0].user_id } : null;
}
