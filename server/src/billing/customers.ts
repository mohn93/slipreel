import type pg from 'pg';
import type Stripe from 'stripe';
import { newId } from '../ids.js';

/**
 * Look up a user by email (the `email` column is citext, so match is
 * case-insensitive), creating the user row and a Stripe customer if absent.
 * Returns the internal user id and the Stripe customer id.
 */
export async function findOrCreateUserByEmail(
  pool: pg.Pool,
  stripe: Stripe,
  email: string,
): Promise<{ userId: string; stripeCustomerId: string }> {
  const existing = await pool.query<{ id: string; stripe_customer_id: string | null }>(
    'SELECT id, stripe_customer_id FROM users WHERE email = $1',
    [email],
  );

  if (existing.rows.length > 0) {
    const row = existing.rows[0]!;
    if (row.stripe_customer_id) {
      return { userId: row.id, stripeCustomerId: row.stripe_customer_id };
    }
    const customer = await stripe.customers.create({ email });
    await pool.query('UPDATE users SET stripe_customer_id = $1 WHERE id = $2', [customer.id, row.id]);
    return { userId: row.id, stripeCustomerId: customer.id };
  }

  const customer = await stripe.customers.create({ email });
  const userId = newId('usr');
  await pool.query(
    'INSERT INTO users (id, email, stripe_customer_id) VALUES ($1, $2, $3)',
    [userId, email, customer.id],
  );
  return { userId, stripeCustomerId: customer.id };
}
