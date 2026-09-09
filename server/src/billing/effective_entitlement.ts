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
    plan: string; status: string; updates_until: Date | null; current_period_end: Date | null; grace_until: Date | null;
  }>(
    `SELECT plan, status, updates_until, current_period_end, grace_until FROM entitlements e WHERE user_id = $1 AND NOT EXISTS (SELECT 1 FROM disputed_payments d WHERE d.stripe_subscription_id = e.stripe_subscription_id AND (d.suspended OR (d.revoked AND (d.revoked_until IS NULL OR d.revoked_until > now()))))`,
    [userId],
  );

  const sub = rows.find(
    (r) => r.plan === 'subscription' && ((r.status === 'active' && !!r.current_period_end && r.current_period_end.getTime() > Date.now()) || (r.status === 'grace' && !!r.grace_until && r.grace_until.getTime() > Date.now())),
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
