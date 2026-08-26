ALTER TABLE magic_links
  ADD COLUMN device_fingerprint text,
  ADD COLUMN device_name text,
  ADD COLUMN state text;
