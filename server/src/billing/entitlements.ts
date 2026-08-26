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
async function userIdForCustomer(
  client: pg.PoolClient,
  customer: unknown,
): Promise<string | null> {
  if (typeof customer !== 'string') return null;
  const { rows } = await client.query<{ id: string }>(
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
 *
 * The claim (recording the event id) and the entitlement writes happen in a
 * single transaction: if a write fails after the claim, the whole transaction
 * rolls back, so the event is NOT marked processed and Stripe's retry will
 * try again. Without this, a failed write after a committed claim would
 * permanently swallow the event.
 */
export async function handleStripeEvent(
  pool: pg.Pool,
  event: Stripe.Event,
): Promise<{ processed: boolean }> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // Idempotency gate: claim the event id, or bail if already claimed.
    const claim = await client.query(
      'INSERT INTO processed_stripe_events (event_id) VALUES ($1) ON CONFLICT DO NOTHING RETURNING event_id',
      [event.id],
    );
    if (claim.rowCount === 0) {
      await client.query('COMMIT');
      return { processed: false };
    }

    switch (event.type) {
      case 'checkout.session.completed': {
        const s = event.data.object as Stripe.Checkout.Session;
        if (s.mode === 'payment') {
          const userId = await userIdForCustomer(client, s.customer);
          if (userId) await extendOnetime(client, userId, s.payment_intent);
        }
        // subscription-mode checkouts are handled by the subscription.* events.
        break;
      }
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
      case 'customer.subscription.deleted': {
        const sub = event.data.object as Stripe.Subscription;
        const userId = await userIdForCustomer(client, sub.customer);
        if (userId) await upsertSubscription(client, userId, sub);
        break;
      }
      default:
        // Recorded above; nothing to apply.
        break;
    }

    await client.query('COMMIT');
    return { processed: true };
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

async function extendOnetime(
  client: pg.PoolClient,
  userId: string,
  paymentIntent: unknown,
): Promise<void> {
  const pi = typeof paymentIntent === 'string' ? paymentIntent : null;
  // Single upsert against the partial unique index on (user_id) WHERE
  // plan = 'onetime' — avoids the SELECT-then-write race that could create
  // duplicate onetime rows under concurrent delivery.
  await client.query(
    `INSERT INTO entitlements
       (id, user_id, plan, status, stripe_payment_intent_id, updates_until)
     VALUES ($1, $2, 'onetime', 'active', $3, now() + interval '1 year')
     ON CONFLICT (user_id) WHERE plan = 'onetime'
     DO UPDATE SET updates_until = GREATEST(entitlements.updates_until, now()) + interval '1 year',
                   status = 'active',
                   stripe_payment_intent_id = EXCLUDED.stripe_payment_intent_id,
                   updated_at = now()`,
    [newId('ent'), userId, pi],
  );
}

async function upsertSubscription(
  client: pg.PoolClient,
  userId: string,
  sub: Stripe.Subscription,
): Promise<void> {
  const status = mapSubscriptionStatus(sub.status);
  // Webhook payloads are rendered at the connected account's API version, not
  // the SDK's pinned default — accounts on API version 2025-03-31.basil or
  // later omit the top-level current_period_end and carry it on the first
  // subscription item instead. Read both shapes defensively; a missing value
  // becomes null (the column is nullable) rather than an Invalid Date that
  // would throw on write.
  const rawEnd =
    (sub as any).current_period_end ?? (sub as any).items?.data?.[0]?.current_period_end;
  const periodEnd = typeof rawEnd === 'number' ? new Date(rawEnd * 1000) : null;
  await client.query(
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
