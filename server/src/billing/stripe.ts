import Stripe from 'stripe';

/** Construct the Stripe client. apiVersion is intentionally omitted; the SDK
 * sends its own bundled default on REST calls regardless of the connected
 * account's settings. Webhook event payloads, however, are rendered at the
 * account's own API version — which can differ from the SDK's default — so
 * entitlement sync code (see billing/entitlements.ts) reads fields like
 * current_period_end defensively to tolerate either version's Subscription
 * shape. Pin apiVersion here if you need a specific one. Used by server.ts
 * (real boot) and scripts/bootstrap-stripe.ts. */
export function createStripeClient(secretKey: string): Stripe {
  return new Stripe(secretKey);
}
