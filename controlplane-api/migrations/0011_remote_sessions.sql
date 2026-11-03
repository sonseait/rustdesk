CREATE TABLE remote_sessions (
    id UUID PRIMARY KEY,
    ticket_id UUID NOT NULL UNIQUE,
    source_device_id UUID NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    target_device_id UUID NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    permission TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('authorized', 'connected', 'ended', 'failed')),
    authorized_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    connected_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    failure_reason TEXT
);

CREATE INDEX remote_sessions_source_authorized_idx ON remote_sessions (source_device_id, authorized_at DESC);
CREATE INDEX remote_sessions_target_authorized_idx ON remote_sessions (target_device_id, authorized_at DESC);
