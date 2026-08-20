DROP TABLE server_node_policies;

CREATE TABLE server_policy (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    anonymous_remote_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    anonymous_max_session_minutes INTEGER NOT NULL DEFAULT 30 CHECK (anonymous_max_session_minutes BETWEEN 1 AND 480),
    anonymous_max_concurrent_devices INTEGER NOT NULL DEFAULT 1 CHECK (anonymous_max_concurrent_devices BETWEEN 1 AND 10000),
    anonymous_max_devices_per_window INTEGER NOT NULL DEFAULT 10 CHECK (anonymous_max_devices_per_window BETWEEN 1 AND 100000),
    anonymous_window_minutes INTEGER NOT NULL DEFAULT 60 CHECK (anonymous_window_minutes BETWEEN 1 AND 1440),
    updated_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO server_policy (singleton) VALUES (TRUE);
