-- Records which completed Checkout sessions have already established a login,
-- so a leaked checkout_session_id cannot be replayed for a second session.
CREATE TABLE consumed_checkout_sessions (
  session_id  text PRIMARY KEY,
  consumed_at timestamptz NOT NULL DEFAULT now()
);
