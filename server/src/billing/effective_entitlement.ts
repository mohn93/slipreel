import type pg from 'pg';

export type EffectiveEntitlement = {
  plan: 'subscription' | 'onetime' | 'free';
  status: 'active' | 'grace' | 'canceled' | 'none';
  updatesUntil: string | null;
  export: boolean;
};

/**
 * Collapse a user's entitlement rows into one effective entitlement:
 * an active/grace subscription wins; else any one-time grants export
 * (the version-ceiling check is client-side); else free.
 */
export async function resolveEffectiveEntitlement(
  pool: pg.Pool,
  userId: string,
): Promise<EffectiveEntitlement> {
  const { rows } = await pool.query<{
    plan: string; status: string; updates_until: Date | null;
  }>(
    `SELECT plan, status, updates_until FROM entitlements WHERE user_id = $1`,
    [userId],
  );

  const sub = rows.find(
    (r) => r.plan === 'subscription' && (r.status === 'active' || r.status === 'grace'),
  );
  if (sub) {
    return { plan: 'subscription', status: sub.status as 'active' | 'grace', updatesUntil: null, export: true };
  }

  const onetime = rows.find((r) => r.plan === 'onetime' && r.status === 'active');
  if (onetime) {
    return {
      plan: 'onetime',
      status: 'active',
      updatesUntil: onetime.updates_until ? onetime.updates_until.toISOString() : null,
      export: true,
    };
  }

  return { plan: 'free', status: 'none', updatesUntil: null, export: false };
}
