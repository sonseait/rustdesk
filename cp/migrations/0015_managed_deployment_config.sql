ALTER TABLE current_server_desired_config
    ADD COLUMN rendezvous_server TEXT NOT NULL DEFAULT '',
    ADD COLUMN relay_server TEXT NOT NULL DEFAULT '',
    ADD COLUMN server_public_key TEXT NOT NULL DEFAULT '';
