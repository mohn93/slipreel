import type pg from 'pg';
import { newId } from '../ids.js';
import { recomputeOnetime } from './entitlements.js';

/** Grant keys share purchase_grants with Stripe payment intents; never a Stripe id. */
export const COMP_PREFIX = 'comp_';

export type CompResult = {
  userId: string;
  createdUser: boolean;
  grantId: string | null;
  entitlement: { status: string; updates_until: Date | null } | null;
};

/**
 * Give an email a complimentary one-time license (same rights as a paid
 * one-time purchase: unlimited exports, one year of updates per grant).
 * Creates the account if needed so the person can sign in by magic link.
 * Runs inside the caller's transaction.
 */
export async function grantComp(client: pg.PoolClient, email: string): Promise<CompResult> {
  const inserted = await client.query<{ id: string }>(
    'INSERT INTO users (id, email) VALUES ($1, $2) ON CONFLICT (email) DO NOTHING RETURNING id',
    [newId('usr'), email],
  );
  const userId = inserted.rows[0]?.id ?? await userIdForEmail(client, email);
  if (!userId) throw new Error(`Could not resolve user for ${email}`);
  const grantId = `${COMP_PREFIX}${newId('grant')}`;
  await client.query(
    'INSERT INTO purchase_grants (payment_intent_id, user_id, purchased_at) VALUES ($1, $2, now())',
    [grantId, userId],
  );
  await recomputeOnetime(client, userId);
  return { userId, createdUser: inserted.rowCount === 1, grantId, entitlement: await onetimeFor(client, userId) };
}

/** Revoke every complimentary grant for an email. Paid grants are untouched. */
export async function revokeComp(client: pg.PoolClient, email: string): Promise<CompResult> {
  const userId = await userIdForEmail(client, email);
  if (!userId) throw new Error(`No account for ${email}`);
  const { rowCount } = await client.query(
    'UPDATE purchase_grants SET revoked = true WHERE user_id = $1 AND payment_intent_id LIKE $2 AND NOT revoked',
    [userId, `${COMP_PREFIX}%`],
  );
  if (!rowCount) throw new Error(`${email} has no active complimentary license`);
  await recomputeOnetime(client, userId);
  return { userId, createdUser: false, grantId: null, entitlement: await onetimeFor(client, userId) };
}

async function userIdForEmail(client: pg.PoolClient, email: string): Promise<string | null> {
  const { rows } = await client.query<{ id: string }>('SELECT id FROM users WHERE email = $1', [email]);
  return rows[0]?.id ?? null;
}

async function onetimeFor(client: pg.PoolClient, userId: string): Promise<CompResult['entitlement']> {
  const { rows } = await client.query<{ status: string; updates_until: Date | null }>(
    "SELECT status, updates_until FROM entitlements WHERE user_id = $1 AND plan = 'onetime'",
    [userId],
  );
  return rows[0] ?? null;
}
