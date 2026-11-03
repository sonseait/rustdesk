ALTER TABLE users
    ADD COLUMN totp_secret_encrypted TEXT,
    ADD COLUMN totp_confirmed_at TIMESTAMPTZ,
    ADD COLUMN totp_last_counter BIGINT;

CREATE INDEX users_totp_enabled_idx ON users (totp_confirmed_at) WHERE totp_confirmed_at IS NOT NULL;
