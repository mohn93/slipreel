import type pg from 'pg';
import type Stripe from 'stripe';
import type { BillingConfig } from './config.js';
import { newId } from '../ids.js';

export function mapSubscriptionStatus(
  stripeStatus: string,
): 'active' | 'grace' | 'canceled' | 'incomplete' {
  switch (stripeStatus) {
    case 'active':
    case 'trialing':
      return 'active';
    case 'past_due':
      return 'grace';
    case 'unpaid':
      return 'canceled';
    case 'canceled':
      return 'canceled';
    default:
      return 'incomplete';
  }
}

/** Stripe omits PaymentIntent for completed orders discounted to zero. */
function isNoCostCheckout(session: Stripe.Checkout.Session): boolean {
  return session.status === 'complete' && session.amount_total === 0 &&
    (session.payment_status === 'paid' || session.payment_status === 'no_payment_required');
}

export function isSettledCheckout(session: Stripe.Checkout.Session): boolean {
  return session.payment_status === 'paid' || isNoCostCheckout(session);
}

function checkoutGrantKey(session: Stripe.Checkout.Session): string | null {
  const pi = typeof session.payment_intent === 'string' ? session.payment_intent : session.payment_intent?.id;
  // The existing text ledger key also supports a namespaced Checkout reference.
  // Replays of the same free order must never extend the license again.
  return pi ?? (isNoCostCheckout(session) && session.id ? `checkout_session:${session.id}` : null);
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
  stripe?: Stripe,
  billing?: BillingConfig,
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
      case 'checkout.session.async_payment_failed': {
        const session = event.data.object as Stripe.Checkout.Session;
        await client.query('INSERT INTO failed_checkouts (session_id) VALUES ($1) ON CONFLICT DO NOTHING', [session.id]);
        break;
      }
      case 'checkout.session.async_payment_succeeded':
      case 'checkout.session.completed': {
        const s = event.data.object as Stripe.Checkout.Session;
        if (s.mode === 'payment' && isSettledCheckout(s)) {
          if (stripe && billing && !(await isExpectedCheckout(stripe, billing, s))) break;
          const userId = await userIdForCustomer(client, s.customer);
          if (userId) await extendOnetime(client, userId, checkoutGrantKey(s), s.created);
        }
        // subscription-mode checkouts are handled by the subscription.* events.
        break;
      }
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
      case 'customer.subscription.deleted': {
        const snapshot = event.data.object as Stripe.Subscription;
        // Serialize retrieval and writing so concurrent deliveries cannot roll back a newer state.
        await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [snapshot.id]);
        const sub = stripe ? await stripe.subscriptions.retrieve(snapshot.id, {expand:['latest_invoice']}) : snapshot;
        if (billing && !sub.items.data.some(i => [billing.prices.monthly, billing.prices.yearly].includes(i.price.id))) break;
        const userId = await userIdForCustomer(client, sub.customer);
        if (userId) await upsertSubscription(client, userId, sub, stripe ? 0 : event.created ?? 0);
        break;
      }
      case 'charge.refunded':
      case 'charge.dispute.created':
      case 'charge.dispute.closed': {
        if (!stripe) break;
        const object = event.data.object as unknown as {id: string; charge?: string};
        const chargeId = event.type === 'charge.refunded' ? object.id : object.charge;
        if (!chargeId) break;
        await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [chargeId]);
        const charge = await stripe.charges.retrieve(chargeId);
        const pi = typeof charge.payment_intent === 'string' ? charge.payment_intent : charge.payment_intent?.id;
        if (!pi) break;
        await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [pi]);
        const legacy = await client.query('SELECT 1 FROM purchase_grants WHERE payment_intent_id = $1 AND legacy_until IS NOT NULL', [pi]);
        if (legacy.rowCount) throw new Error('Legacy purchase history requires reconciliation before reversal');
        const invoiceId = typeof charge.invoice === 'string' ? charge.invoice : charge.invoice?.id;
        const invoice = invoiceId ? await stripe.invoices.retrieve(invoiceId) : null;
        const subscriptionRef = invoice?.subscription ?? (invoice as any)?.parent?.subscription_details?.subscription;
        const subscriptionId = typeof subscriptionRef === 'string' ? subscriptionRef : subscriptionRef?.id;
        let suspended = false;
        let lost = false;
        if (event.type !== 'charge.refunded') {
          const dispute = await stripe.disputes.retrieve(object.id);
          suspended = !['won', 'lost', 'warning_closed'].includes(dispute.status);
          lost = dispute.status === 'lost';
        }
        const refunded = charge.refunded && charge.amount_refunded >= charge.amount;
        await client.query(`INSERT INTO disputed_payments (payment_intent_id, suspended, revoked, stripe_subscription_id, revoked_until)
          VALUES ($1,$2,$3,$4,$6) ON CONFLICT (payment_intent_id) DO UPDATE SET
          suspended = CASE WHEN $5 THEN EXCLUDED.suspended ELSE disputed_payments.suspended END,
          revoked = disputed_payments.revoked OR EXCLUDED.revoked,
          stripe_subscription_id = COALESCE(EXCLUDED.stripe_subscription_id, disputed_payments.stripe_subscription_id),
          revoked_until = COALESCE(EXCLUDED.revoked_until, disputed_payments.revoked_until)`,
          [pi, suspended, refunded || lost, subscriptionId ?? null, event.type !== 'charge.refunded', invoice ? new Date(Math.max(invoice.period_end, ...invoice.lines.data.map(line => line.period.end)) * 1000) : null]);
        const {rows} = await client.query<{user_id: string}>(`UPDATE purchase_grants p SET revoked = d.revoked, suspended = d.suspended
          FROM disputed_payments d WHERE p.payment_intent_id = d.payment_intent_id AND p.payment_intent_id = $1 RETURNING p.user_id`, [pi]);
        if (rows[0]) await recomputeOnetime(client, rows[0].user_id);
        // Subscription disputes suspend access until resolved, without destroying
        // the subscription's independent Stripe status.
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
  purchasedAt?: number,
): Promise<void> {
  const pi = typeof paymentIntent === 'string' ? paymentIntent : null;
  if (!pi) return;
  await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [pi]);
  await client.query('SELECT id FROM users WHERE id = $1 FOR UPDATE', [userId]);
  const grant = await client.query(`INSERT INTO purchase_grants (payment_intent_id, user_id, purchased_at, revoked, suspended) VALUES ($1,$2,COALESCE($3,now()), COALESCE((SELECT revoked FROM disputed_payments WHERE payment_intent_id=$1),false), COALESCE((SELECT suspended FROM disputed_payments WHERE payment_intent_id=$1),false)) ON CONFLICT DO NOTHING RETURNING payment_intent_id`, [pi, userId, purchasedAt ? new Date(purchasedAt * 1000) : null]);
  if (!grant.rowCount) return;
  await recomputeOnetime(client, userId);
}

export async function recomputeOnetime(client: pg.PoolClient, userId: string): Promise<void> {
  await client.query('SELECT id FROM users WHERE id = $1 FOR UPDATE', [userId]);
  const {rows} = await client.query<{purchased_at: Date; legacy_until: Date | null; payment_intent_id: string}>(
    'SELECT purchased_at, legacy_until, payment_intent_id FROM purchase_grants WHERE user_id = $1 AND NOT revoked AND NOT suspended ORDER BY purchased_at, payment_intent_id', [userId]);
  let until: Date | null = null;
  for (const row of rows) {
    if (row.legacy_until) { until = row.legacy_until; continue; }
    const next: pg.QueryResult<{until: Date}> = await client.query<{until: Date}>("SELECT GREATEST($1::timestamptz, $2::timestamptz) + interval '1 year' AS until", [until, row.purchased_at]);
    until = next.rows[0]!.until;
  }
  await client.query(`INSERT INTO entitlements (id,user_id,plan,status,updates_until,stripe_payment_intent_id)
    VALUES ($1,$2,'onetime',$3,$4,$5) ON CONFLICT (user_id) WHERE plan = 'onetime'
    DO UPDATE SET status = EXCLUDED.status, updates_until = EXCLUDED.updates_until,
      stripe_payment_intent_id = EXCLUDED.stripe_payment_intent_id, updated_at = now()`,
    [newId('ent'), userId, until ? 'active' : 'canceled', until, rows.at(-1)?.payment_intent_id ?? null]);
}

async function upsertSubscription(
  client: pg.PoolClient,
  userId: string,
  sub: Stripe.Subscription,
  eventCreated = 0,
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
  const invoice = typeof sub.latest_invoice === 'object' ? sub.latest_invoice : null;
  const rawStart = invoice?.due_date ?? invoice?.status_transitions?.finalized_at ?? (sub as any).current_period_start ?? (sub as any).items?.data?.[0]?.current_period_start ?? (eventCreated || Date.now()/1000);
  const graceStart = new Date(Math.min(rawStart * 1000, Date.now()));
  await client.query(
    `INSERT INTO entitlements
       (id, user_id, plan, status, stripe_subscription_id, current_period_end, stripe_event_created, grace_until)
     VALUES ($1, $2, 'subscription', $3, $4, $5, $6, CASE WHEN $3 = 'grace' THEN $7::timestamptz + interval '7 days' ELSE NULL END)
     ON CONFLICT (stripe_subscription_id) WHERE stripe_subscription_id IS NOT NULL
     DO UPDATE SET status = EXCLUDED.status,
                   current_period_end = EXCLUDED.current_period_end,
                   updated_at = now(),
                   stripe_event_created = EXCLUDED.stripe_event_created,
                   grace_until = CASE WHEN EXCLUDED.status = 'grace' THEN COALESCE(entitlements.grace_until, EXCLUDED.grace_until) ELSE NULL END
     WHERE EXCLUDED.stripe_event_created = 0 OR entitlements.stripe_event_created <= EXCLUDED.stripe_event_created`,
    [newId('ent'), userId, status, sub.id, periodEnd, eventCreated, graceStart],
  );
}

/** Verify the purchased price rather than trusting caller-controlled metadata. */
export async function isExpectedCheckout(stripe: Stripe, billing: BillingConfig, session: Stripe.Checkout.Session, historicalOnetimePrices: string[] = []): Promise<boolean> {
  const lines = await stripe.checkout.sessions.listLineItems(session.id, {limit: 100});
  const prices = session.mode === 'payment' ? [billing.prices.onetime, ...historicalOnetimePrices] : [billing.prices.monthly, billing.prices.yearly];
  return !lines.has_more && lines.data.length === 1 && lines.data[0]?.quantity === 1 && prices.includes(lines.data[0]?.price?.id ?? '');
}

/** Success-page and webhook reconciliation share purchase-level idempotency. */
export async function reconcileCheckout(pool: pg.Pool, stripe: Stripe, billing: BillingConfig, session: Stripe.Checkout.Session): Promise<boolean> {
  if (session.status !== 'complete' || !isSettledCheckout(session) || !(await isExpectedCheckout(stripe, billing, session))) return false;
  if (session.mode === 'payment') {
    const key = checkoutGrantKey(session);
    if (!key) return false;
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const userId = await userIdForCustomer(client, session.customer);
      if (!userId) throw new Error('Unknown checkout customer');
      // Purchase-level idempotency permits recovery even if an earlier webhook
      // or reconciliation was recorded without granting this no-cost order.
      await extendOnetime(client, userId, key, session.created);
      await client.query('COMMIT');
      return true;
    } catch (err) { await client.query('ROLLBACK'); throw err; }
    finally { client.release(); }
  }
  const id = typeof session.subscription === 'string' ? session.subscription : session.subscription?.id;
  if (!id) return false;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [id]);
    const sub = await stripe.subscriptions.retrieve(id, {expand:['latest_invoice']});
    const userId = await userIdForCustomer(client, sub.customer);
    if (!userId) throw new Error('Unknown subscription customer');
    await upsertSubscription(client, userId, sub);
    await client.query('COMMIT');
    return sub.status === 'active' || sub.status === 'trialing';
  } catch (err) { await client.query('ROLLBACK'); throw err; }
  finally { client.release(); }
}
