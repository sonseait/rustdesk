ALTER TABLE server_nodes
    ADD COLUMN health JSONB NOT NULL DEFAULT '{}'::jsonb;
