CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE users (
  id                 text PRIMARY KEY,
  email              citext UNIQUE NOT NULL,
  password_hash      text NOT NULL,
  email_verified     boolean NOT NULL DEFAULT false,
  stripe_customer_id text UNIQUE,
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE entitlements (
  id                       text PRIMARY KEY,
  user_id                  text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan                     text NOT NULL CHECK (plan IN ('subscription', 'onetime')),
  status                   text NOT NULL CHECK (status IN ('active', 'grace', 'canceled', 'incomplete')),
  stripe_subscription_id   text,
  stripe_payment_intent_id text,
  current_period_end       timestamptz,
  updates_until            timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX entitlements_user_id_idx ON entitlements(user_id);

CREATE TABLE devices (
  id                 text PRIMARY KEY,
  user_id            text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  fingerprint        text NOT NULL,
  name               text,
  refresh_token_hash text NOT NULL,
  last_seen_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, fingerprint)
);

CREATE TABLE processed_stripe_events (
  event_id     text PRIMARY KEY,
  processed_at timestamptz NOT NULL DEFAULT now()
);
