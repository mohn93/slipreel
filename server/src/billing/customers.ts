import type pg from 'pg';
import type Stripe from 'stripe';
import { newId } from '../ids.js';

/** Attach a Stripe customer once, serializing concurrent verified checkouts. */
export async function findOrCreateUserByEmail(pool: pg.Pool, stripe: Stripe, email: string): Promise<{userId: string; stripeCustomerId: string}> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('INSERT INTO users (id,email) VALUES ($1,$2) ON CONFLICT (email) DO NOTHING', [newId('usr'),email]);
    const {rows} = await client.query<{id:string;stripe_customer_id:string|null}>('SELECT id,stripe_customer_id FROM users WHERE email = $1 FOR UPDATE',[email]);
    const user = rows[0]!;
    let id = user.stripe_customer_id;
    if (!id) {
      const customer = await stripe.customers.create({email}, {idempotencyKey:`customer_${user.id}`});
      id = customer.id;
      await client.query('UPDATE users SET stripe_customer_id = $1 WHERE id = $2',[id,user.id]);
    }
    await client.query('COMMIT');
    return {userId:user.id,stripeCustomerId:id};
  } catch(err) { await client.query('ROLLBACK'); throw err; }
  finally { client.release(); }
}
