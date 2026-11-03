CREATE TABLE sessions (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ
);

CREATE INDEX sessions_active_token_idx ON sessions (token_hash, expires_at)
WHERE revoked_at IS NULL;

-- This governs only uncredentialed RustDesk traffic at a server node. It does
-- not grant a control-plane session or any portal permission.
CREATE TABLE server_node_policies (
    node_id UUID PRIMARY KEY,
    allow_anonymous_remote BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
