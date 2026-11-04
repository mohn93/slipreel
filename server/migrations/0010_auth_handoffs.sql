-- Cross-device sign-in: the browser that approves a Mac app sign-in (often a
-- phone) leaves the minted device credentials here for the app to claim.
-- `id` is a hash of the app's secret state nonce and `payload` is encrypted
-- with a key derived from that nonce, so a row is unreadable without it.
CREATE TABLE auth_handoffs (
  id text PRIMARY KEY,
  fingerprint text NOT NULL,
  payload text NOT NULL,
  expires_at timestamptz NOT NULL
);
CREATE INDEX auth_handoffs_expires_idx ON auth_handoffs(expires_at);
