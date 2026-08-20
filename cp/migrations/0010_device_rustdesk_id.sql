ALTER TABLE devices ADD COLUMN rustdesk_id TEXT NOT NULL DEFAULT '';
CREATE UNIQUE INDEX devices_rustdesk_id_active_idx ON devices (rustdesk_id)
WHERE rustdesk_id <> '' AND revoked_at IS NULL;
