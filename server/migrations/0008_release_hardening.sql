ALTER TABLE magic_links ADD COLUMN checkout_plan text CHECK (checkout_plan IN ('monthly','onetime'));
ALTER TABLE magic_links ADD COLUMN checkout_session_id text;
ALTER TABLE magic_links ADD COLUMN checkout_flow text;
CREATE TABLE checkout_flows (
 id text PRIMARY KEY, user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 context jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE purchase_grants (
 payment_intent_id text PRIMARY KEY, user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 purchased_at timestamptz NOT NULL DEFAULT now(), revoked boolean NOT NULL DEFAULT false
);
ALTER TABLE entitlements ADD COLUMN stripe_event_created bigint NOT NULL DEFAULT 0;
ALTER TABLE purchase_grants ADD COLUMN suspended boolean NOT NULL DEFAULT false;
ALTER TABLE purchase_grants ADD COLUMN legacy_until timestamptz;
-- Preserve existing one-time ceilings. Earlier payments were not recorded, so
-- operators must reconcile their history from Stripe before processing old refunds.
INSERT INTO purchase_grants (payment_intent_id, user_id, purchased_at, legacy_until)
SELECT COALESCE(stripe_payment_intent_id, 'legacy_' || id), user_id, created_at, updates_until FROM entitlements
WHERE plan = 'onetime' AND status = 'active';
ALTER TABLE entitlements ADD COLUMN grace_until timestamptz;
CREATE TABLE disputed_payments (
 payment_intent_id text PRIMARY KEY, suspended boolean NOT NULL, updated_at timestamptz NOT NULL DEFAULT now()
);
-- Pre-fix checkout could mint sessions and device credentials without email proof.
DELETE FROM sessions;
UPDATE devices SET refresh_token_hash = 'revoked-before-verified-checkout';
ALTER TABLE disputed_payments ADD COLUMN stripe_subscription_id text;
ALTER TABLE disputed_payments ADD COLUMN revoked boolean NOT NULL DEFAULT false;
DELETE FROM magic_links;
ALTER TABLE disputed_payments ADD COLUMN revoked_until timestamptz;
CREATE TABLE failed_checkouts (session_id text PRIMARY KEY, failed_at timestamptz NOT NULL DEFAULT now());
