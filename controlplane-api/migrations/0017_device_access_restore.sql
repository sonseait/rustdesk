-- Recovery is available only after an explicit administrator restore.
ALTER TABLE devices ADD COLUMN access_restored_at TIMESTAMPTZ;
