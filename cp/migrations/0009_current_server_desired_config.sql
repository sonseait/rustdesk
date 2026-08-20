CREATE TABLE current_server_desired_config (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    revision BIGINT NOT NULL DEFAULT 1 CHECK (revision >= 1),
    managed_mode TEXT NOT NULL DEFAULT 'off' CHECK (managed_mode IN ('off', 'optional', 'required')),
    credential_issuer_public_key TEXT,
    updated_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO current_server_desired_config (singleton) VALUES (TRUE);
