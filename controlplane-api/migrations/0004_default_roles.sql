INSERT INTO roles (id, name, description) VALUES
    ('00000000-0000-0000-0000-000000000001', 'operator', 'Can use managed remote access'),
    ('00000000-0000-0000-0000-000000000002', 'auditor', 'Can review audit events')
ON CONFLICT (name) DO NOTHING;
