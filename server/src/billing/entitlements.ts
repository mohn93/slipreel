import type pg from 'pg';
import type Stripe from 'stripe';
import { newId } from '../ids.js';

export function mapSubscriptionStatus(
  stripeStatus: string,
): 'active' | 'grace' | 'canceled' | 'incomplete' {
  switch (stripeStatus) {
    case 'active':
    case 'trialing':
      return 'active';
    case 'past_due':
    case 'unpaid':
      return 'grace';
    case 'canceled':
      return 'canceled';
    default:
      return 'incomplete';
  }
}

/** Resolve our user id from a Stripe customer id; null if unknown. */
async function userIdForCustomer(pool: pg.Pool, customer: unknown): Promise<string | null> {
  if (typeof customer !== 'string') return null;
  const { rows } = await pool.query<{ id: string }>(
    'SELECT id FROM users WHERE stripe_customer_id = $1',
    [customer],
  );
  return rows[0]?.id ?? null;
}

/**
 * Apply a Stripe event to the entitlements table, idempotently. The first time
 * an event id is seen it is recorded in processed_stripe_events and applied;
 * subsequent deliveries are skipped. Unknown event types are recorded and
 * ignored.
 */
export async function handleStripeEvent(
  pool: pg.Pool,
  event: Stripe.Event,
): Promise<{ processed: boolean }> {
  // Idempotency gate: claim the event id, or bail if already claimed.
  const claim = await pool.query(
    'INSERT INTO processed_stripe_events (event_id) VALUES ($1) ON CONFLICT DO NOTHING RETURNING event_id',
    [event.id],
  );
  if (claim.rowCount === 0) return { processed: false };

  switch (event.type) {
    case 'checkout.session.completed': {
      const s = event.data.object as Stripe.Checkout.Session;
      if (s.mode === 'payment') {
        const userId = await userIdForCustomer(pool, s.customer);
        if (userId) await extendOnetime(pool, userId, s.payment_intent);
      }
      // subscription-mode checkouts are handled by the subscription.* events.
      break;
    }
    case 'customer.subscription.created':
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted': {
      const sub = event.data.object as Stripe.Subscription;
      const userId = await userIdForCustomer(pool, sub.customer);
      if (userId) await upsertSubscription(pool, userId, sub);
      break;
    }
    default:
      // Recorded above; nothing to apply.
      break;
  }
  return { processed: true };
}

async function extendOnetime(
  pool: pg.Pool,
  userId: string,
  paymentIntent: unknown,
): Promise<void> {
  const pi = typeof paymentIntent === 'string' ? paymentIntent : null;
  const existing = await pool.query<{ id: string }>(
    `SELECT id FROM entitlements WHERE user_id = $1 AND plan = 'onetime'`,
    [userId],
  );
  if (existing.rows.length > 0) {
    // Extend from the later of now or the current ceiling, by one year.
    await pool.query(
      `UPDATE entitlements
         SET updates_until = GREATEST(updates_until, now()) + interval '1 year',
             status = 'active',
             stripe_payment_intent_id = $2,
             updated_at = now()
       WHERE id = $1`,
      [existing.rows[0]!.id, pi],
    );
  } else {
    await pool.query(
      `INSERT INTO entitlements
         (id, user_id, plan, status, stripe_payment_intent_id, updates_until)
       VALUES ($1, $2, 'onetime', 'active', $3, now() + interval '1 year')`,
      [newId('ent'), userId, pi],
    );
  }
}

async function upsertSubscription(
  pool: pg.Pool,
  userId: string,
  sub: Stripe.Subscription,
): Promise<void> {
  const status = mapSubscriptionStatus(sub.status);
  const periodEnd = new Date(sub.current_period_end * 1000);
  await pool.query(
    `INSERT INTO entitlements
       (id, user_id, plan, status, stripe_subscription_id, current_period_end)
     VALUES ($1, $2, 'subscription', $3, $4, $5)
     ON CONFLICT (stripe_subscription_id) WHERE stripe_subscription_id IS NOT NULL
     DO UPDATE SET status = EXCLUDED.status,
                   current_period_end = EXCLUDED.current_period_end,
                   updated_at = now()`,
    [newId('ent'), userId, status, sub.id, periodEnd],
  );
}
