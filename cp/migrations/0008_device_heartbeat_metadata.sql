ALTER TABLE devices
    ADD COLUMN last_capabilities JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN last_health JSONB NOT NULL DEFAULT '{}'::jsonb;
