-- A user row can exist before any password is set (created at checkout).
ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL;

-- Enable upsert of a subscription entitlement keyed by its Stripe id.
CREATE UNIQUE INDEX entitlements_stripe_subscription_id_key
  ON entitlements (stripe_subscription_id)
  WHERE stripe_subscription_id IS NOT NULL;
