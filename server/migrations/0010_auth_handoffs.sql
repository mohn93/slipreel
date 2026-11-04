-- Cross-device sign-in: the browser that approves a Mac app sign-in (often a
-- phone) leaves the minted device credentials here for the app to claim.
-- A row is opened when a magic link / checkout carrying the app's state nonce
-- is verified (binding it to that user and device), filled by /v1/token, and
-- claimed once by the app. `id` is an HMAC of the nonce under a server secret
-- and `payload` is encrypted with a key derived the same way.
CREATE TABLE auth_handoffs (
  id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  fingerprint text NOT NULL,
  payload text,
  claimed_at timestamptz,
  expires_at timestamptz NOT NULL
);
CREATE INDEX auth_handoffs_expires_idx ON auth_handoffs(expires_at);
