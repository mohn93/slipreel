-- Coarse device location (country name), derived server-side from the
-- Cloudflare cf-ipcountry header at register/refresh. Shown in the account
-- device list; nullable (unknown / header absent).
ALTER TABLE devices ADD COLUMN IF NOT EXISTS location text;
