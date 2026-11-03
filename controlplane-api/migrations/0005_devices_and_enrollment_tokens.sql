CREATE TABLE enrollment_tokens (
    id UUID PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    label TEXT NOT NULL,
    max_enrollments INTEGER NOT NULL DEFAULT 1 CHECK (max_enrollments BETWEEN 1 AND 10000),
    enrollment_count INTEGER NOT NULL DEFAULT 0,
    expires_at TIMESTAMPTZ NOT NULL,
    created_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ
);

CREATE TABLE devices (
    id UUID PRIMARY KEY,
    display_name TEXT NOT NULL,
    hostname TEXT NOT NULL,
    operating_system TEXT NOT NULL,
    client_version TEXT NOT NULL,
    public_key_fingerprint TEXT NOT NULL UNIQUE,
    enrollment_token_id UUID REFERENCES enrollment_tokens(id) ON DELETE SET NULL,
    enrolled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ
);

CREATE INDEX devices_active_idx ON devices (revoked_at, last_seen_at DESC);
