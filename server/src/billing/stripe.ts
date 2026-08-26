import Stripe from 'stripe';

/** Construct the Stripe client. apiVersion is intentionally omitted so the
 * account's default pinned version is used; pin it here if you need a specific
 * one. Used by server.ts (real boot) and scripts/bootstrap-stripe.ts. */
export function createStripeClient(secretKey: string): Stripe {
  return new Stripe(secretKey);
}
