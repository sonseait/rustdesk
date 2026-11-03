CREATE TABLE permissions (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL
);

CREATE TABLE role_permissions (
    role_id UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_id UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE device_groups (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE device_group_members (
    device_group_id UUID NOT NULL REFERENCES device_groups(id) ON DELETE CASCADE,
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    PRIMARY KEY (device_group_id, device_id)
);

CREATE TABLE device_tags (
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    tag TEXT NOT NULL CHECK (char_length(tag) BETWEEN 1 AND 64),
    PRIMARY KEY (device_id, tag)
);

CREATE TABLE server_nodes (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    endpoint TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'unknown',
    last_seen_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE policy_revisions (
    id UUID PRIMARY KEY,
    revision BIGINT NOT NULL UNIQUE,
    policy JSONB NOT NULL,
    created_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE signing_keys (
    id UUID PRIMARY KEY,
    public_key TEXT NOT NULL UNIQUE,
    state TEXT NOT NULL CHECK (state IN ('active', 'retiring', 'retired')),
    not_before TIMESTAMPTZ NOT NULL,
    not_after TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX device_group_members_device_idx ON device_group_members (device_id);
CREATE INDEX device_tags_tag_idx ON device_tags (tag);
CREATE INDEX server_nodes_last_seen_idx ON server_nodes (last_seen_at DESC);
