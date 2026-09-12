-- Payment providers have separate records. Neither webhook updates the other's rows.
ALTER TABLE users ADD COLUMN app_account_token uuid NOT NULL DEFAULT gen_random_uuid();
CREATE UNIQUE INDEX users_app_account_token_key ON users(app_account_token);
CREATE TABLE apple_subscriptions (
  original_transaction_id text NOT NULL,
  environment text NOT NULL CHECK(environment IN ('Production','Sandbox')),
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  product_id text NOT NULL,
  transaction_id text NOT NULL,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  signed_at timestamptz NOT NULL,
  checked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(original_transaction_id, environment)
);
CREATE INDEX apple_subscriptions_user_idx ON apple_subscriptions(user_id);
CREATE TABLE native_auth_challenges (
  id text PRIMARY KEY,
  email citext,
  secret_hash text NOT NULL,
  kind text NOT NULL CHECK(kind IN ('email','apple')),
  attempts integer NOT NULL DEFAULT 0,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz
);
CREATE TABLE apple_identities (
  subject text PRIMARY KEY,
  user_id text NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  refresh_token_encrypted text NOT NULL
);
-- One physical device seat, independent credentials for the two app editions.
CREATE TABLE store_device_credentials (
  device_id text PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  refresh_token_hash text NOT NULL
);
