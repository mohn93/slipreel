import Stripe from 'stripe';

/** REST reconciliation deliberately uses the SDK's tested Acacia shape.
 * Webhook snapshots may use another version; retrieve their objects by ID. */
export function createStripeClient(secretKey: string): Stripe {
  return new Stripe(secretKey, {apiVersion: '2025-02-24.acacia'});
}
